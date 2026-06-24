import Foundation

// MARK: - DownloadProgress

/// Live progress snapshot for a single in-flight download.
public struct DownloadProgress: Sendable {
    /// Bytes received so far.
    public let bytesReceived: Int64
    /// Expected total bytes (nil when the server did not send Content-Length).
    public let totalBytes: Int64?

    /// A fractional progress value in [0, 1], or `nil` when total is unknown.
    public var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1.0, Double(bytesReceived) / Double(total))
    }
}

// MARK: - DownloadManager

/// Downloads original track files from a Navidrome server, stores them on
/// disk under `<Application Support>/Adagio Stream/Downloads/`, and tracks
/// lifecycle state in the GRDB `downloads` table.
///
/// **Concurrency model** — matches `ProviderManager`: `@MainActor`
/// `ObservableObject` so SwiftUI views can observe `@Published` properties
/// directly.  Heavy work (URLSession, file I/O) is dispatched onto the
/// cooperative thread pool via `Task.detached`; only state mutations run on
/// the main actor.
///
/// **Concurrency limit** — at most `maxConcurrentDownloads` transfers run
/// simultaneously.  Additional calls to `download(track:via:)` while the
/// limit is reached are queued as `.queued` rows and will be started
/// automatically when a slot frees up.
///
/// **Background downloads** — this bead uses standard `async/await` download
/// tasks (not `URLSessionConfiguration.background`).  Background-session
/// downloads continue when the app is suspended and are the gold standard
/// for a production download manager; that work is tracked as a follow-up
/// (l31-bg: background-session downloads).  For this cut the download will
/// be paused if the app is killed; partially-received bytes are NOT resumed
/// (resumeData support is also a follow-up).
///
/// **Resume** — `resumeOffset` is stored in the row but full byte-range
/// resume (via `URLSession` `resumeData`) is deferred.  On failure the
/// status is set to `.failed`; a retry calls `download(track:via:)` again
/// which starts a fresh download from byte 0.
@MainActor
public final class DownloadManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = DownloadManager()

    // MARK: - Max concurrent downloads

    /// Maximum number of simultaneous URLSession download tasks.
    /// Increasing this too high hammers the server and saturates the network.
    public let maxConcurrentDownloads = 3

    // MARK: - Observable state

    /// Live progress for in-flight downloads, keyed by track ID.
    @Published public private(set) var progress: [String: DownloadProgress] = [:]

    /// Snapshot of all known download records.  Refreshed after every state change.
    @Published public private(set) var downloads: [DownloadRecord] = []

    // MARK: - Private state

    private let store: NavidromeStore
    private let downloadsDirectory: URL

    /// Active download tasks keyed by track ID.
    private var activeTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    /// Production initialiser — uses the shared GRDB store.
    public convenience init() {
        self.init(store: NavidromeStore.shared)
    }

    /// Injectable initialiser for tests.
    init(store: NavidromeStore) {
        self.store = store

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        downloadsDirectory = appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )

        // Hydrate the observable snapshot on init.
        refreshDownloads()

        // Any rows stuck in `.downloading` from a previous run never completed
        // (process was killed mid-download).  Mark them `.failed` so the UI
        // does not show phantom "downloading" indicators.
        Task { @MainActor [weak self] in
            self?.markStuckDownloadsFailed()
        }
    }

    // MARK: - Public API

    /// Starts (or resumes) a download for the given track.
    ///
    /// - Parameters:
    ///   - track: The `Track` record to download.
    ///   - api: The `NavidromeAPI` instance to use for building the download URL.
    ///
    /// If a completed download already exists for the track ID this method is
    /// a no-op.  If a previous failed/paused row exists it is reset to queued
    /// and re-enqueued.
    public func download(track: Track, via api: NavidromeAPI) {
        let trackID = track.id

        // Idempotency guard — don't re-download a completed track.
        if let existing = try? store.download(forTrackID: trackID),
           existing.status == .completed {
            return
        }

        let now = Int(Date().timeIntervalSince1970)
        let suffix = track.suffix ?? "audio"
        let localPath = downloadsDirectory
            .appendingPathComponent("\(trackID).\(suffix)")
            .path

        let record = DownloadRecord(
            id: trackID,
            status: .queued,
            localPath: localPath,
            resumeOffset: 0,
            error: nil,
            createdAt: now,
            updatedAt: now
        )

        try? store.upsert(download: record)
        refreshDownloads()

        drainQueue(api: api)
    }

    /// Cancels an in-flight or queued download.  The GRDB row is left with
    /// status `.failed` so the UI can show "cancelled".
    public func cancelDownload(trackID: String) {
        activeTasks[trackID]?.cancel()
        activeTasks.removeValue(forKey: trackID)
        progress.removeValue(forKey: trackID)

        try? store.updateDownload(
            trackID: trackID,
            status: .failed,
            error: "Cancelled"
        )
        refreshDownloads()
    }

    /// Deletes the download row and any associated on-disk file.
    public func deleteDownload(trackID: String) {
        // Cancel first if active.
        activeTasks[trackID]?.cancel()
        activeTasks.removeValue(forKey: trackID)
        progress.removeValue(forKey: trackID)

        // Remove the file if it exists.
        if let record = try? store.download(forTrackID: trackID),
           let path = record.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        try? store.deleteDownload(forTrackID: trackID)
        refreshDownloads()
    }

    /// Returns the on-disk URL for a completed download, or `nil` when the
    /// track is not yet downloaded or the file is missing.
    ///
    /// l31.3 (local-first playback) uses this to obtain the local file URL
    /// before falling back to a stream URL.
    public func localFileURL(forTrackID trackID: String) -> URL? {
        guard let record = try? store.download(forTrackID: trackID),
              record.status == .completed,
              let path = record.localPath,
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Returns `true` when a completed, on-disk download exists for the track.
    public func isDownloaded(trackID: String) -> Bool {
        localFileURL(forTrackID: trackID) != nil
    }

    // MARK: - Storage accounting

    /// Returns the total number of bytes consumed by completed downloads.
    /// Computed from file sizes on disk — not from a stored value.
    public func totalDownloadedBytes() -> Int64 {
        (try? store.totalDownloadedBytes()) ?? 0
    }

    /// Deletes all download rows and their on-disk files.
    public func clearAllDownloads() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        progress.removeAll()

        try? store.deleteAllDownloads()
        refreshDownloads()
    }

    // MARK: - Queue drain

    /// Starts queued downloads up to `maxConcurrentDownloads`.
    private func drainQueue(api: NavidromeAPI) {
        guard activeTasks.count < maxConcurrentDownloads else { return }

        let queuedRows = (try? store.downloads(withStatus: .queued)) ?? []

        for record in queuedRows {
            guard activeTasks.count < maxConcurrentDownloads else { break }
            guard activeTasks[record.id] == nil else { continue }

            let trackID = record.id
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.executeDownload(trackID: trackID, api: api)
            }
            activeTasks[trackID] = task
        }
    }

    // MARK: - Core download execution

    /// Runs a single URLSession download task for `trackID`, writing the result
    /// to the pre-determined local path.  Transitions status through
    /// queued → downloading → completed (or failed).
    private func executeDownload(trackID: String, api: NavidromeAPI) async {
        guard let url = api.downloadURL(trackID: trackID) else {
            try? store.updateDownload(
                trackID: trackID,
                status: .failed,
                error: "Could not build download URL"
            )
            refreshDownloads()
            activeTasks.removeValue(forKey: trackID)
            return
        }

        // Fetch the destination path from the record.
        guard let record = try? store.download(forTrackID: trackID),
              let localPath = record.localPath
        else {
            activeTasks.removeValue(forKey: trackID)
            return
        }

        let destinationURL = URL(fileURLWithPath: localPath)

        // Mark as .downloading.
        try? store.updateDownload(trackID: trackID, status: .downloading)
        refreshDownloads()

        do {
            let session = URLSession.shared
            let (tempURL, response) = try await session.download(from: url)

            // Guard against task cancellation.
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                activeTasks.removeValue(forKey: trackID)
                return
            }

            // Check HTTP status.
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }

            // Move temp file to the final path.
            // Remove any stale file at the destination first.
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            // Apply file protection so the file is accessible after first unlock
            // and survives background finalization.
            let attrs: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: localPath)

            // Retrieve file size for resumeOffset / storage accounting.
            let fileSize = (try? FileManager.default.attributesOfItem(
                atPath: localPath
            ))?[.size] as? Int ?? 0

            try? store.updateDownload(
                trackID: trackID,
                status: .completed,
                localPath: localPath,
                resumeOffset: fileSize
            )
        } catch {
            if Task.isCancelled { return }
            try? store.updateDownload(
                trackID: trackID,
                status: .failed,
                error: error.localizedDescription
            )
        }

        activeTasks.removeValue(forKey: trackID)
        progress.removeValue(forKey: trackID)
        refreshDownloads()
    }

    // MARK: - Helpers

    /// Refreshes the `downloads` published array from the store.
    private func refreshDownloads() {
        downloads = (try? store.allDownloads()) ?? []
    }

    /// Marks rows that are stuck in `.downloading` (from a prior killed process)
    /// as `.failed` so they can be retried.
    private func markStuckDownloadsFailed() {
        let stuck = (try? store.downloads(withStatus: .downloading)) ?? []
        for record in stuck {
            // Only mark stuck if there is no active task for this ID.
            guard activeTasks[record.id] == nil else { continue }
            try? store.updateDownload(
                trackID: record.id,
                status: .failed,
                error: "Interrupted — tap to retry"
            )
        }
        if !stuck.isEmpty { refreshDownloads() }
    }
}
