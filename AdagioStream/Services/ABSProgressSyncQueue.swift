// MARK: - Audiobookshelf Offline Progress Sync Queue (E3 / mkj.2)
//
// While offline (or when a server sync fails), audiobook progress is appended
// here instead of hitting `/api/session/{id}/sync`. On reconnect the queue is
// flushed in ONE `PATCH /api/me/progress/batch/update` request (bare JSON
// array). Only the latest position per book is kept — a book listened to across
// several offline sessions collapses to one update, which is all the server
// needs (last-writer-wins on `lastUpdate`).
//
// The queue persists to disk so pending progress survives an app relaunch
// before connectivity returns. The dedup/merge logic is pure and unit-tested;
// disk + network are thin wrappers around it.

import Foundation

/// Persisted, deduped queue of offline audiobook progress updates.
public actor ABSProgressSyncQueue {

    public static let shared = ABSProgressSyncQueue()

    private let fileURL: URL
    private var pending: [ABSProgressUpdate]

    /// - Parameter fileURL: override for tests; defaults to App Support.
    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultFileURL()
        self.fileURL = url
        self.pending = Self.load(from: url)
    }

    // MARK: - Pure merge (unit-tested)

    /// Merges a new update into an existing queue, keeping ONE entry per
    /// `(libraryItemId, episodeId)` — the one with the newest `lastUpdate`. A
    /// stale update (older than what's already queued) is dropped so a
    /// late-arriving background flush can't rewind progress.
    ///
    /// Keying on the pair (not just `libraryItemId`) matters once podcasts are
    /// in the queue: two episodes of the same show share `libraryItemId` and
    /// must not collide into one entry. `episodeId == nil` (books) behaves
    /// exactly as before — same single-key dedup.
    public static func merge(_ existing: [ABSProgressUpdate], with update: ABSProgressUpdate) -> [ABSProgressUpdate] {
        var result = existing
        if let idx = result.firstIndex(where: {
            $0.libraryItemId == update.libraryItemId && $0.episodeId == update.episodeId
        }) {
            if update.lastUpdate >= result[idx].lastUpdate {
                result[idx] = update
            }
            return result
        }
        result.append(update)
        return result
    }

    // MARK: - Queue ops

    /// Adds (or supersedes) a book's progress in the queue and persists it.
    public func enqueue(_ update: ABSProgressUpdate) {
        pending = Self.merge(pending, with: update)
        persist()
    }

    /// Current pending updates (snapshot).
    public func snapshot() -> [ABSProgressUpdate] { pending }

    /// The queued offline `currentTime` for one book (or one episode of a show,
    /// when `episodeId` is given), or `nil` if nothing is pending for it. Used
    /// to seed a live OR offline resume so playback can't rewind to an older
    /// position (ymf.6) or start over at 0 when a flush hasn't landed yet.
    ///
    /// `episodeId` MUST be passed when looking up an episode — two episodes of
    /// the same show share `libraryItemId`, so a book-only lookup (`nil`)
    /// against a show id would match whichever episode happened to be queued,
    /// not necessarily the one being resumed (beads_mobilemusic-uxc kickback).
    /// Defaulting to `nil` keeps existing book call sites unchanged.
    public func pendingPosition(forBook id: String, episodeId: String? = nil) -> Double? {
        pending.first { $0.libraryItemId == id && $0.episodeId == episodeId }?.currentTime
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Flushes the queue via the batch endpoint. On a 2xx the queue is cleared;
    /// otherwise it is kept for the next attempt. A network error also keeps the
    /// queue. Returns true when the flush succeeded (or there was nothing to send).
    @discardableResult
    public func flush(via api: AudiobookshelfAPI) async -> Bool {
        guard !pending.isEmpty else { return true }
        let batch = pending
        do {
            let status = try await api.batchUpdateProgress(batch)
            guard (200...299).contains(status) else { return false }
            // Only clear the items we actually sent — anything enqueued during
            // the request is preserved.
            let sentIDs = Set(batch.map(\.libraryItemId))
            pending.removeAll { sentIDs.contains($0.libraryItemId) && batch.contains($0) }
            persist()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Persistence

    private func persist() {
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL)
    }

    private static func load(from url: URL) -> [ABSProgressUpdate] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ABSProgressUpdate].self, from: data)
        else { return [] }
        return items
    }

    private static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("abs-progress-queue.json")
    }
}
