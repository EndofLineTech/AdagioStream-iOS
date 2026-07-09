// Audiobookshelf E2 / yu8.1 — library browsing view-model.
//
// Mirrors NavidromeLibraryViewModel: @MainActor ObservableObject, LoadState-
// driven, errors surface AudiobookshelfAPI.APIError.errorDescription. Shared
// across iOS/tvOS (no UIKit here).
//
// Books blend into the existing library UI (PO decision: no separate tab). The
// VM fetches book libraries + their items, caches them to the shared store
// (reusing the E1 audiobooks/chapters tables), and exposes a selected book's
// chapters for the detail screen (yu8.4).

import Foundation

@MainActor
public final class AudiobookshelfLibraryViewModel: ObservableObject {

    // MARK: - Book list

    @Published public private(set) var books: [Audiobook] = []
    @Published public private(set) var booksState: LoadState = .idle

    /// Book libraries seen on the last `loadBooks` (id + name), for grouping the
    /// book list per library (6z5). One entry when the server has a single book
    /// library.
    @Published public private(set) var libraries: [ABSLibraryDTO] = []

    // MARK: - Continue Listening (00t)

    /// In-progress, not-finished books in server order (GET /api/me/items-in-progress).
    @Published public private(set) var inProgress: [Audiobook] = []

    // MARK: - Book detail (chapters)

    @Published public private(set) var selectedBook: Audiobook?
    @Published public private(set) var chapters: [AudiobookChapter] = []
    @Published public private(set) var detailState: LoadState = .idle

    // MARK: - Cover URLs (resolved async — ABS covers are token-in-query URLs)

    /// Resolved cover URLs keyed by book id. Populated as `loadBooks` completes.
    @Published public private(set) var coverURLs: [String: URL] = [:]

    /// Whether the signed-in user may download (gates the download affordance,
    /// E3 / mkj.1). Populated on first `loadBooks`. The server still 403s the
    /// file endpoint if this is wrong, which the download path handles.
    @Published public private(set) var canDownload = false

    private let api: AudiobookshelfAPI

    public init(api: AudiobookshelfAPI) {
        self.api = api
    }

    /// Exposed so views can start playback via `AudioPlayerService.playAudiobook`.
    public var audiobookshelfAPI: AudiobookshelfAPI { api }

    // MARK: - Load: all books across all book libraries

    public func loadBooks() async {
        guard booksState != .loading else { return }
        // Reconnect point: flush any progress queued while offline (E3 / mkj.2).
        await ABSProgressSyncQueue.shared.flush(via: api)
        booksState = .loading
        do {
            let libraries = try await api.bookLibraries()
            self.libraries = libraries
            var all: [Audiobook] = []
            let now = Int(Date().timeIntervalSince1970)
            for library in libraries {
                let items = try await api.items(inLibrary: library.id)
                all.append(contentsOf: items.map { $0.toRecord(libraryIdFallback: library.id, updatedAt: now) })
            }
            all.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            books = all
            // Cache to the shared store (E1 tables) so offline/other screens read it.
            try? NavidromeStore.shared.upsert(audiobooks: all)
            booksState = all.isEmpty ? .empty : .loaded
            canDownload = await api.canDownload()
            await resolveCovers(for: all)
        } catch let apiErr as AudiobookshelfAPI.APIError {
            booksState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            booksState = .error(error.localizedDescription)
        }
    }

    // MARK: - Continue Listening (00t)

    /// Loads the Continue-Listening shelf from `/api/me/items-in-progress`.
    /// Keeps server order (most-recently-listened first). Best-effort: leaves the
    /// shelf empty on failure so the main book list still renders.
    public func loadInProgress() async {
        guard let items = try? await api.itemsInProgress() else { return }
        let now = Int(Date().timeIntervalSince1970)
        let records = Self.inProgressBooks(from: items, updatedAt: now)
        inProgress = records
        await resolveCovers(for: records)
    }

    /// Maps in-progress DTOs to records, dropping finished/unstarted books.
    /// Pure so the filter/order is unit-testable. Server order is preserved.
    static func inProgressBooks(from items: [ABSLibraryItemDTO], updatedAt: Int) -> [Audiobook] {
        items
            .map { $0.toRecord(libraryIdFallback: $0.libraryId ?? "", updatedAt: updatedAt) }
            .filter { !$0.isFinished && $0.progress > 0 }
    }

    private func resolveCovers(for books: [Audiobook]) async {
        for book in books {
            if let url = await api.coverURL(itemID: book.id) {
                coverURLs[book.id] = url
            }
        }
    }

    // MARK: - Load: one book's detail (fresh progress + chapters)

    /// Fetches the expanded item (progress + `media.chapters[]`), persists
    /// chapters, and exposes them for the detail screen. Falls back to cached
    /// chapters on failure so the list still renders offline.
    public func loadDetail(for book: Audiobook) async {
        selectedBook = book
        chapters = (try? NavidromeStore.shared.chapters(forBook: book.id)) ?? []
        detailState = .loading
        do {
            let item = try await api.item(id: book.id)
            let fresh = item.chapters()
            try? NavidromeStore.shared.replaceChapters(fresh, forBook: book.id)
            // Refresh the progress-bearing record too.
            let updated = item.toRecord(libraryIdFallback: book.libraryId, updatedAt: Int(Date().timeIntervalSince1970))
            try? NavidromeStore.shared.upsert(audiobooks: [updated])
            selectedBook = updated
            if let i = books.firstIndex(where: { $0.id == updated.id }) { books[i] = updated }
            chapters = fresh.sorted { $0.start < $1.start }
            detailState = .loaded
        } catch let apiErr as AudiobookshelfAPI.APIError {
            // Keep cached chapters; only surface the error if we have nothing.
            detailState = chapters.isEmpty ? .error(apiErr.errorDescription ?? "Unknown error") : .loaded
        } catch {
            detailState = chapters.isEmpty ? .error(error.localizedDescription) : .loaded
        }
    }

    public func resetDetail() {
        selectedBook = nil
        chapters = []
        detailState = .idle
    }

    // MARK: - Offline download (E3 / mkj.1)

    /// Builds the download manifest for a book and starts the per-file downloads
    /// via `DownloadManager`.
    ///
    /// ymf.4: each file's global `startOffset` is captured from a live `/play`
    /// session's server-authoritative `audioTracks[]` — NOT recomputed from
    /// `media.audioFiles[].duration`. The two can diverge: the play session drops
    /// `exclude`d audioFiles and re-sums offsets over only the included ones
    /// (`Book.getTracklist` uses `includedAudioFiles`, while the item-detail JSON
    /// serializes ALL audioFiles). Recomputing would then include phantom
    /// durations and skew every offset. We join `audioTracks[].startOffset`
    /// (offline-timeline truth) with `audioFiles[].ino` (the download key) by
    /// `index`. Returns silently if the book can't be direct-played (no session,
    /// no tracks, or transcode — which collapses to one track with no per-file ino).
    public func downloadBook(_ book: Audiobook, using downloadManager: DownloadManager) async {
        let item: ABSLibraryItemDTO
        let session: ABSPlaybackSessionDTO
        do {
            item = try await api.item(id: book.id)
            session = try await api.openPlaybackSession(itemID: book.id, deviceID: AudioPlayerService.absDeviceID)
        } catch {
            return
        }

        guard let files = Self.downloadFiles(session: session, audioFiles: item.audioFiles()) else { return }
        let chapters = item.chapters()
        let total = files.map { $0.startOffset + $0.duration }.max() ?? 0

        downloadManager.downloadBook(
            itemID: book.id,
            title: book.title,
            author: book.author,
            coverPath: book.coverPath,
            duration: book.duration ?? session.duration ?? total,
            files: files,
            chapters: chapters,
            via: api
        )
    }

    /// Joins the play session's server-authoritative `audioTracks[].startOffset`
    /// with each file's downloadable `ino` (matched by `index`) into a download
    /// manifest. Pure so the join/skip logic is unit-testable.
    ///
    /// Returns `nil` (book not downloadable per-file) when the session transcodes
    /// (`playMethod == 1`), has no tracks, or no track can be paired with an
    /// `ino` — none of those can be reassembled from per-file downloads offline.
    nonisolated static func downloadFiles(session: ABSPlaybackSessionDTO, audioFiles: [ABSAudioFileDTO]) -> [AudiobookDownloadFile]? {
        // Transcode sessions return a single synthetic track with no per-file ino.
        guard session.playMethod != 1 else { return nil }
        let tracks = (session.audioTracks ?? []).sorted { $0.startOffset < $1.startOffset }
        guard !tracks.isEmpty else { return nil }

        let inoByIndex = Dictionary(audioFiles.map { ($0.index, $0.ino) }, uniquingKeysWith: { first, _ in first })
        let files: [AudiobookDownloadFile] = tracks.compactMap { track in
            guard let ino = inoByIndex[track.index], !ino.isEmpty else { return nil }
            return AudiobookDownloadFile(
                index: track.index,
                ino: ino,
                startOffset: track.startOffset,   // server-authoritative
                duration: track.duration
            )
        }
        // Every track must map to a downloadable file, or offline playback would
        // have a hole in the timeline.
        guard files.count == tracks.count else { return nil }
        return files
    }
}
