import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
/// **Concurrency model** — `@MainActor` `ObservableObject` so SwiftUI views
/// can observe `@Published` properties directly.  The background URLSession
/// delegate callbacks arrive on `delegateQueue` (a serial background queue)
/// and hop onto the main actor via `Task { @MainActor in … }` for all state
/// mutations.
///
/// **Background URLSession** — uses
/// `URLSessionConfiguration.background(withIdentifier:)` so in-flight
/// downloads continue when the app is backgrounded or suspended by iOS.
/// The session identifier is `com.adagiostream.downloads`.
///
/// **Task ↔ trackId mapping** — each `URLSessionDownloadTask` has its
/// `taskDescription` set to the Navidrome track ID.  This survives across
/// app restarts: on relaunch `reconcileBackgroundSession()` iterates the
/// session's existing tasks and reconciles them with the GRDB row for each
/// `taskDescription`.
///
/// **Concurrency cap** — the background session handles its own scheduling.
/// We still gate `download()` with an in-memory `enqueued` set so we do not
/// accidentally create duplicate tasks if `download()` is called twice before
/// a relaunch reconciliation completes.
///
/// **Byte-range resume** — when a task fails or is cancelled, `resumeData`
/// (an opaque blob) is persisted to
/// `<AppSupport>/Adagio Stream/ResumeData/<trackId>.resumedata`.  On the
/// next call to `download()` the data is read back and the task is created
/// via `downloadTask(withResumeData:)`.  If the resume data is stale or
/// unavailable, a fresh download is started from byte 0.
///
/// **Launch reconciliation** — on init the manager queries the background
/// session's running tasks.  Tasks that are still running are left alone
/// (their GRDB row stays `.downloading`).  Rows stuck in `.downloading`
/// with NO corresponding live task are marked `.failed` so the UI shows a
/// retry prompt.
///
/// **tvOS** — `URLSession(configuration: .background(…))` exists on tvOS;
/// the `handleEventsForBackgroundURLSession` app-delegate callback is
/// iOS-only and is guarded with `#if os(iOS)`.
@MainActor
public final class DownloadManager: NSObject, ObservableObject {

    // MARK: - Background session identifier

    public static let backgroundSessionIdentifier = "com.adagiostream.downloads"

    // MARK: - Singleton

    public static let shared = DownloadManager()

    // MARK: - Max concurrent downloads

    /// The background URLSession manages its own scheduling.  This constant
    /// is kept for API compatibility and informational purposes.
    public let maxConcurrentDownloads = 3

    // MARK: - Observable state

    /// Live progress for in-flight downloads, keyed by track ID.
    @Published public private(set) var progress: [String: DownloadProgress] = [:]

    /// Snapshot of all known download records.  Refreshed after every state change.
    @Published public private(set) var downloads: [DownloadRecord] = []

    /// Snapshot of all audiobook download records (E3 / mkj.1). Separate from
    /// `downloads` (music tracks) so the two offline lists never mix.
    @Published public private(set) var audiobookDownloads: [AudiobookDownloadRecord] = []

    // MARK: - Private state

    private let store: NavidromeStore
    private let downloadsDirectory: URL

    /// The background URLSession.  `self` is the delegate.
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Tracks IDs of tasks we have enqueued in the current process so we can
    /// avoid creating duplicate tasks if download() is called twice quickly.
    private var enqueuedTrackIDs: Set<String> = []

    /// The ABS API per in-flight book, so a background file task that 401s can
    /// re-fetch a fresh token and re-enqueue itself (ymf.5). Keyed by bookID.
    private var bookAPIs: [String: AudiobookshelfAPI] = [:]

    /// Book file task descriptions we've already re-authed once, so a persistent
    /// 401 fails the book instead of looping (ymf.5 — one re-auth per file).
    private var reauthedBookTasks: Set<String> = []

    // MARK: - Static path helpers (nonisolated — safe to call from delegates)

    /// Derives the resume-data directory path without accessing any
    /// actor-isolated state.  Safe to call from `nonisolated` delegate methods.
    nonisolated static func resumeDataDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("ResumeData", isDirectory: true)
    }

    /// Returns the on-disk URL for resume data keyed by track ID.
    /// Safe to call from `nonisolated` contexts.
    nonisolated static func resumeDataURL(forTrackID trackID: String) -> URL {
        resumeDataDirectory().appendingPathComponent("\(trackID).resumedata")
    }

    /// Derives the downloads directory path without accessing any
    /// actor-isolated state.  Safe to call from `nonisolated` delegate methods.
    nonisolated static func downloadsDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - Init

    /// Production initialiser — uses the shared GRDB store.
    public convenience override init() {
        self.init(store: NavidromeStore.shared)
    }

    /// Injectable initialiser for tests.
    init(store: NavidromeStore) {
        self.store = store

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent(Constants.appName, isDirectory: true)
        downloadsDirectory = appDir.appendingPathComponent("Downloads", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: Self.resumeDataDirectory(),
            withIntermediateDirectories: true
        )

        super.init()

        // Hydrate the observable snapshots on init.
        refreshDownloads()
        refreshAudiobookDownloads()

        // Reconcile the background session with the DB — running tasks are
        // left alive; stuck rows (no live task) are marked .failed.
        Task { @MainActor [weak self] in
            await self?.reconcileBackgroundSession()
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
    /// and re-enqueued.  Byte-range resume is attempted automatically when
    /// persisted resume data exists for the track.
    public func download(track: Track, via api: NavidromeAPI) {
        let trackID = track.id

        // Idempotency guard — don't re-download a completed track.
        if let existing = try? store.download(forTrackID: trackID),
           existing.status == .completed {
            return
        }

        // Don't create a duplicate task if one is already enqueued or running.
        if enqueuedTrackIDs.contains(trackID) { return }

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

        startBackgroundTask(trackID: trackID, api: api)
    }

    /// Cancels an in-flight or queued download, capturing resumeData for
    /// later byte-range resume.  The GRDB row is left with status `.failed`.
    public func cancelDownload(trackID: String) {
        progress.removeValue(forKey: trackID)
        enqueuedTrackIDs.remove(trackID)

        // Find the live task and cancel it, requesting resume data.
        backgroundSession.getAllTasks { tasks in
            let matchingTask = tasks.first { $0.taskDescription == trackID }
            if let downloadTask = matchingTask as? URLSessionDownloadTask {
                downloadTask.cancel(byProducingResumeData: { data in
                    if let data {
                        Self.persistResumeData(data, forTrackID: trackID)
                    }
                })
            } else {
                matchingTask?.cancel()
            }
        }

        try? store.updateDownload(
            trackID: trackID,
            status: .failed,
            error: "Cancelled"
        )
        refreshDownloads()
    }

    /// Deletes the download row and any associated on-disk file and resume data.
    public func deleteDownload(trackID: String) {
        progress.removeValue(forKey: trackID)
        enqueuedTrackIDs.remove(trackID)

        // Cancel the task if it is running.
        backgroundSession.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == trackID })?.cancel()
        }

        // Remove the file if it exists.
        if let record = try? store.download(forTrackID: trackID),
           let path = record.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        // Remove persisted resume data.
        Self.clearResumeData(forTrackID: trackID)

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

    /// Deletes all download rows, on-disk files, and resume data blobs.
    public func clearAllDownloads() {
        enqueuedTrackIDs.removeAll()
        progress.removeAll()

        backgroundSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }

        // Clear all persisted resume data files.
        let rdDir = Self.resumeDataDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(
            at: rdDir,
            includingPropertiesForKeys: nil
        ) {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        try? store.deleteAllDownloads()
        refreshDownloads()
    }

    // MARK: - Background completion handler (iOS only)

    #if os(iOS)
    /// The system-provided completion handler for the background session.
    /// Set by `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// and called from `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    var backgroundCompletionHandler: (() -> Void)?
    #endif

    // MARK: - Resume data helpers (nonisolated static — callable from delegate methods)

    /// Persists resume data to disk for future byte-range resume.
    nonisolated static func persistResumeData(_ data: Data, forTrackID trackID: String) {
        let url = resumeDataURL(forTrackID: trackID)
        // Ensure the directory exists (may not on first launch after update).
        try? FileManager.default.createDirectory(
            at: resumeDataDirectory(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
    }

    /// Loads persisted resume data for a track without removing it.
    /// Returns nil when no resume data exists.
    nonisolated static func loadResumeData(forTrackID trackID: String) -> Data? {
        let url = resumeDataURL(forTrackID: trackID)
        return try? Data(contentsOf: url)
    }

    /// Removes any persisted resume data file for a track.
    nonisolated static func clearResumeData(forTrackID trackID: String) {
        let url = resumeDataURL(forTrackID: trackID)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Task creation

    /// Creates and resumes a background download task for `trackID`.
    /// Uses persisted resume data for byte-range continuation when available.
    private func startBackgroundTask(trackID: String, api: NavidromeAPI) {
        // Consume (load + delete) the resume data atomically.
        let resumeDataURL = Self.resumeDataURL(forTrackID: trackID)
        let resumeData = (try? Data(contentsOf: resumeDataURL))
        if resumeData != nil {
            try? FileManager.default.removeItem(at: resumeDataURL)
        }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = backgroundSession.downloadTask(withResumeData: resumeData)
        } else {
            guard let url = api.downloadURL(trackID: trackID) else {
                try? store.updateDownload(
                    trackID: trackID,
                    status: .failed,
                    error: "Could not build download URL"
                )
                refreshDownloads()
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            task = backgroundSession.downloadTask(with: request)
        }
        task.taskDescription = trackID
        enqueuedTrackIDs.insert(trackID)

        try? store.updateDownload(trackID: trackID, status: .downloading)
        refreshDownloads()

        task.resume()
    }

    // MARK: - Audiobook downloads (E3 / mkj.1)

    /// taskDescription marker for a book file: `abs#<bookId>#<ino>`. Music tasks
    /// use the bare trackID, so the `abs#` prefix cleanly disambiguates the two
    /// in the shared URLSession delegate.
    nonisolated static func bookTaskDescription(bookID: String, ino: String) -> String {
        "abs#\(bookID)#\(ino)"
    }

    /// Parses a book-file taskDescription back into `(bookID, ino)`, or `nil`
    /// when the description is a plain music trackID.
    nonisolated static func parseBookTaskDescription(_ desc: String) -> (bookID: String, ino: String)? {
        guard desc.hasPrefix("abs#") else { return nil }
        let parts = desc.dropFirst(4).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// On-disk path for one book file. Books live under `Downloads/abs/<bookId>/`
    /// so a whole book deletes as a directory and never collides with music.
    nonisolated static func bookFilePath(bookID: String, ino: String) -> String {
        downloadsDirectory()
            .appendingPathComponent("abs", isDirectory: true)
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent("\(ino).audio")
            .path
    }

    /// Starts downloading every file of a book. `files` carry the global
    /// `startOffset`/`duration` from the streaming session joined with each
    /// file's `ino`; the manifest is persisted immediately so a relaunch can
    /// reconcile in-flight file tasks and offline playback can rebuild the
    /// timeline. Completed / in-progress books are a no-op.
    public func downloadBook(
        itemID: String,
        title: String,
        author: String?,
        coverPath: String?,
        duration: Double?,
        files: [AudiobookDownloadFile],
        chapters: [AudiobookChapter],
        via api: AudiobookshelfAPI
    ) {
        guard !files.isEmpty else { return }

        if let existing = try? store.audiobookDownload(forBook: itemID),
           existing.status == .completed || existing.status == .downloading {
            return
        }

        // Ensure the book directory exists.
        let bookDir = Self.downloadsDirectory()
            .appendingPathComponent("abs", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try? FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

        let now = Int(Date().timeIntervalSince1970)
        let record = AudiobookDownloadRecord(
            id: itemID,
            title: title,
            author: author,
            coverPath: coverPath,
            duration: duration,
            status: .downloading,
            files: files,          // localPath nil until each file lands
            chapters: chapters,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
        try? store.upsert(audiobookDownload: record)
        refreshAudiobookDownloads()

        // Keep the API so a 401'd file task can re-auth and re-enqueue (ymf.5).
        bookAPIs[itemID] = api

        // Fetch a live token once, then enqueue a task per file with the Bearer
        // header. Token-in-header keeps short-lived JWTs out of URLs/logs.
        Task { @MainActor in
            let token = await api.currentAccessToken()
            for file in files {
                self.enqueueBookFileTask(bookID: itemID, ino: file.ino, token: token, api: api)
            }
        }
    }

    /// Enqueues one book file's background download task with a Bearer token.
    /// Shared by the initial download and the 401 re-auth retry (ymf.5).
    private func enqueueBookFileTask(bookID: String, ino: String, token: String?, api: AudiobookshelfAPI) {
        guard let url = api.fileDownloadURL(itemID: bookID, ino: ino) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = backgroundSession.downloadTask(with: request)
        task.taskDescription = Self.bookTaskDescription(bookID: bookID, ino: ino)
        task.resume()
    }

    /// On a 401 for a book file (stale snapshot token after OS-deferral), fetch a
    /// fresh token and re-enqueue JUST that file — at most once per file — instead
    /// of failing the whole book (ymf.5). Returns false if we've already retried
    /// this file or have no API for the book, so the caller fails it.
    @MainActor
    fileprivate func retryBookFileAfterAuth(bookID: String, ino: String) async -> Bool {
        let desc = Self.bookTaskDescription(bookID: bookID, ino: ino)
        guard !reauthedBookTasks.contains(desc), let api = bookAPIs[bookID] else { return false }
        reauthedBookTasks.insert(desc)
        let stale = await api.currentAccessToken()
        guard let fresh = await api.refreshedAccessToken(stale: stale) else { return false }
        enqueueBookFileTask(bookID: bookID, ino: ino, token: fresh, api: api)
        return true
    }

    /// Deletes a downloaded book: cancels any in-flight file tasks, removes the
    /// on-disk directory + manifest row.
    public func deleteBookDownload(itemID: String) {
        backgroundSession.getAllTasks { tasks in
            for task in tasks {
                if let desc = task.taskDescription,
                   Self.parseBookTaskDescription(desc)?.bookID == itemID {
                    task.cancel()
                }
            }
        }
        // Remove the whole book directory (covers files not yet in the manifest).
        let bookDir = Self.downloadsDirectory()
            .appendingPathComponent("abs", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
        try? FileManager.default.removeItem(at: bookDir)
        try? store.deleteAudiobookDownload(forBook: itemID)
        forgetBookRetryState(bookID: itemID)
        refreshAudiobookDownloads()
    }

    /// The offline `AudiobookTimeline` for a fully-downloaded book, or `nil` if
    /// the book isn't completely downloaded. Used by offline playback (mkj.2).
    public func downloadedBook(itemID: String) -> AudiobookDownloadRecord? {
        guard let record = try? store.audiobookDownload(forBook: itemID),
              record.status == .completed, record.allFilesPresent
        else { return nil }
        return record
    }

    /// True when a book is fully downloaded and present on disk.
    public func isBookDownloaded(itemID: String) -> Bool {
        downloadedBook(itemID: itemID) != nil
    }

    /// Records that one book file finished downloading: stamps its `localPath`
    /// in the manifest and, when every file is present, flips the book to
    /// `.completed`. Called from the shared download delegate.
    fileprivate func markBookFileComplete(bookID: String, ino: String, localPath: String) {
        guard var record = try? store.audiobookDownload(forBook: bookID) else { return }
        if let idx = record.files.firstIndex(where: { $0.ino == ino }) {
            record.files[idx].localPath = localPath
        }
        record.updatedAt = Int(Date().timeIntervalSince1970)
        if record.allFilesPresent {
            record.status = .completed
            forgetBookRetryState(bookID: bookID)
        }
        try? store.upsert(audiobookDownload: record)
        refreshAudiobookDownloads()
    }

    /// Marks a book download failed (a file task errored). Best-effort.
    fileprivate func markBookFileFailed(bookID: String, error: String) {
        guard var record = try? store.audiobookDownload(forBook: bookID),
              record.status != .completed else { return }
        record.status = .failed
        record.error = error
        record.updatedAt = Int(Date().timeIntervalSince1970)
        forgetBookRetryState(bookID: bookID)
        try? store.upsert(audiobookDownload: record)
        refreshAudiobookDownloads()
    }

    /// Drops the per-book API + re-auth bookkeeping once the book is settled
    /// (completed, failed, or deleted) so the maps don't grow unbounded (ymf.5).
    private func forgetBookRetryState(bookID: String) {
        bookAPIs.removeValue(forKey: bookID)
        let prefix = Self.bookTaskDescription(bookID: bookID, ino: "")
        reauthedBookTasks = reauthedBookTasks.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: - Launch reconciliation

    /// Re-attaches to the background session and reconciles in-flight tasks
    /// with the GRDB `downloads` table.
    ///
    /// Logic:
    /// - Tasks still running in the background session → leave them running;
    ///   ensure their DB row is `.downloading` and add their IDs to
    ///   `enqueuedTrackIDs`.
    /// - DB rows in `.downloading` with no corresponding live task → the
    ///   download was genuinely killed (not just backgrounded); mark `.failed`.
    func reconcileBackgroundSession() async {
        let tasks = await withCheckedContinuation { continuation in
            backgroundSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }

        let liveTaskTrackIDs: Set<String> = Set(
            tasks.compactMap { $0.taskDescription }
        )

        // Register live tasks in the in-memory enqueued set.
        for id in liveTaskTrackIDs {
            enqueuedTrackIDs.insert(id)
        }

        // Mark stuck rows (downloading with no live task) as failed.
        let stuck = (try? store.downloads(withStatus: .downloading)) ?? []
        var didChange = false
        for record in stuck {
            guard !liveTaskTrackIDs.contains(record.id) else { continue }
            try? store.updateDownload(
                trackID: record.id,
                status: .failed,
                error: "Interrupted — tap to retry"
            )
            didChange = true
        }
        if didChange { refreshDownloads() }

        // Same for audiobook downloads: a book stuck in .downloading with no
        // live file task (and not all files on disk) is genuinely interrupted.
        let liveBookIDs = Set(tasks.compactMap {
            $0.taskDescription.flatMap { Self.parseBookTaskDescription($0)?.bookID }
        })
        let stuckBooks = (try? store.audiobookDownloads(withStatus: .downloading)) ?? []
        var didChangeBooks = false
        for var book in stuckBooks {
            if liveBookIDs.contains(book.id) { continue }
            if book.allFilesPresent {
                book.status = .completed        // all files landed before quit
            } else {
                book.status = .failed
                book.error = "Interrupted — tap to retry"
            }
            book.updatedAt = Int(Date().timeIntervalSince1970)
            try? store.upsert(audiobookDownload: book)
            didChangeBooks = true
        }
        if didChangeBooks { refreshAudiobookDownloads() }
    }

    // MARK: - Helpers

    /// Refreshes the `downloads` published array from the store.
    private func refreshDownloads() {
        downloads = (try? store.allDownloads()) ?? []
    }

    /// Refreshes the `audiobookDownloads` published array from the store.
    func refreshAudiobookDownloads() {
        audiobookDownloads = (try? store.allAudiobookDownloads()) ?? []
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    /// Called when a download task finishes successfully.
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let trackID = downloadTask.taskDescription else { return }

        // Audiobook file? Handle on the book path and return (music logic below
        // is keyed by the single `downloads` table row).
        if let (bookID, ino) = Self.parseBookTaskDescription(trackID) {
            finishBookFileDownload(bookID: bookID, ino: ino, task: downloadTask, location: location)
            return
        }

        // Derive the destination path from the DB record (contains the
        // correct extension from the original Track.suffix).
        let localPath: String
        if let record = try? NavidromeStore.shared.download(forTrackID: trackID),
           let path = record.localPath {
            localPath = path
        } else {
            // Fallback: infer path from the track ID and a generic extension.
            localPath = Self.downloadsDirectory()
                .appendingPathComponent("\(trackID).audio")
                .path
        }

        let destinationURL = URL(fileURLWithPath: localPath)

        // Check HTTP status.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enqueuedTrackIDs.remove(trackID)
                self.progress.removeValue(forKey: trackID)
                try? self.store.updateDownload(
                    trackID: trackID,
                    status: .failed,
                    error: "HTTP \(http.statusCode)"
                )
                self.refreshDownloads()
            }
            return
        }

        // Move the temp file to the final destination.
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enqueuedTrackIDs.remove(trackID)
                self.progress.removeValue(forKey: trackID)
                try? self.store.updateDownload(
                    trackID: trackID,
                    status: .failed,
                    error: error.localizedDescription
                )
                self.refreshDownloads()
            }
            return
        }

        // Apply CPUFA file protection.
        let attrs: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: localPath)

        // File size for resumeOffset / storage accounting.
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: localPath
        ))?[.size] as? Int ?? 0

        // Clear any stale resume data since the download succeeded.
        Self.clearResumeData(forTrackID: trackID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueuedTrackIDs.remove(trackID)
            self.progress.removeValue(forKey: trackID)
            try? self.store.updateDownload(
                trackID: trackID,
                status: .completed,
                localPath: localPath,
                resumeOffset: fileSize
            )
            self.refreshDownloads()
        }
    }

    /// Called periodically as bytes arrive — drives the `@Published progress` dictionary.
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let trackID = downloadTask.taskDescription else { return }
        // Book files aren't tracked in the music `progress` dict (keyed by trackID).
        if Self.parseBookTaskDescription(trackID) != nil { return }
        let snapshot = DownloadProgress(
            bytesReceived: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        )
        Task { @MainActor [weak self] in
            self?.progress[trackID] = snapshot
        }
    }

    /// Called when a task completes — either successfully (handled above) or
    /// with an error.  Successful completion calls `didFinishDownloadingTo`
    /// first, so by the time this fires for a success case the row is already
    /// `.completed`; we only need to handle the error path here.
    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }   // success handled in didFinishDownloadingTo
        guard let trackID = task.taskDescription else { return }

        // Audiobook file error → mark the book failed (unless user-cancelled).
        if let (bookID, _) = Self.parseBookTaskDescription(trackID) {
            let nsErr = error as NSError
            let isCancelled = nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled
            if !isCancelled {
                Task { @MainActor [weak self] in
                    self?.markBookFileFailed(bookID: bookID, error: error.localizedDescription)
                }
            }
            return
        }

        // Attempt to capture resume data from the error userInfo.
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        if let resumeData {
            Self.persistResumeData(resumeData, forTrackID: trackID)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueuedTrackIDs.remove(trackID)
            self.progress.removeValue(forKey: trackID)

            // Don't overwrite a .completed row — the success delegate was
            // called first.
            if let existing = try? self.store.download(forTrackID: trackID),
               existing.status == .completed {
                return
            }

            // Don't mark cancelled tasks as failed with a confusing message —
            // cancelDownload() already sets the error.
            let nsErr = error as NSError
            let isCancelled = nsErr.domain == NSURLErrorDomain &&
                              nsErr.code == NSURLErrorCancelled
            if !isCancelled {
                try? self.store.updateDownload(
                    trackID: trackID,
                    status: .failed,
                    error: error.localizedDescription
                )
                self.refreshDownloads()
            }
        }
    }

    /// Moves a finished book file to its on-disk home and updates the manifest.
    /// A non-2xx status fails the whole book with a clear message — EXCEPT a 401,
    /// where a snapshot token likely went stale after OS-deferral: we re-auth and
    /// re-enqueue just this file once (ymf.5), only failing if that retry can't run.
    private nonisolated func finishBookFileDownload(
        bookID: String,
        ino: String,
        task: URLSessionDownloadTask,
        location: URL
    ) {
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            if http.statusCode == 401 {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if await self.retryBookFileAfterAuth(bookID: bookID, ino: ino) { return }
                    self.markBookFileFailed(bookID: bookID, error: "Download failed (HTTP 401).")
                }
                return
            }
            let message = http.statusCode == 403
                ? "Download not permitted for this account."
                : "Download failed (HTTP \(http.statusCode))."
            Task { @MainActor [weak self] in
                self?.markBookFileFailed(bookID: bookID, error: message)
            }
            return
        }

        let localPath = Self.bookFilePath(bookID: bookID, ino: ino)
        let destination = URL(fileURLWithPath: localPath)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor [weak self] in
                self?.markBookFileFailed(bookID: bookID, error: error.localizedDescription)
            }
            return
        }
        // Match music downloads' file protection.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: localPath
        )

        Task { @MainActor [weak self] in
            self?.markBookFileComplete(bookID: bookID, ino: ino, localPath: localPath)
        }
    }

    /// Called when ALL events for a background session have been delivered.
    /// Invoke the stored iOS completion handler to tell the system the app is
    /// done processing and the snapshot can be taken.
    public nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        #if os(iOS)
        Task { @MainActor [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
        #endif
    }
}
