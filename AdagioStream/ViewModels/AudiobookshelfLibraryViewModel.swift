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

    // MARK: - Continue Listening (00t; episodes added E3 / c2s.3)

    /// In-progress, not-finished books in server order (GET /api/me/items-in-progress).
    @Published public private(set) var inProgress: [Audiobook] = []

    /// In-progress podcast episodes from the SAME items-in-progress response
    /// (c2s.3 — rendered in the same Continue Listening shelf as books, not a
    /// separate row).
    @Published public private(set) var inProgressEpisodes: [PodcastEpisodeEntry] = []

    // MARK: - Podcasts (E3 / c2s.1, c2s.2)

    @Published public private(set) var podcastShows: [PodcastShow] = []
    @Published public private(set) var podcastShowsState: LoadState = .idle

    /// Podcast libraries seen on the last `loadPodcastShows`, for gating the
    /// Podcasts section in the library selector (c2s.1).
    @Published public private(set) var podcastLibraries: [ABSLibraryDTO] = []

    /// Whether the ABS provider has at least one podcast library — the exact
    /// gate `MusicLibraryView` uses to decide whether to offer the Podcasts
    /// section at all (c2s.1), mirroring how Books is gated on `books`/`libraries`.
    public var hasPodcastLibrary: Bool { !podcastLibraries.isEmpty }

    /// Cover URLs for podcast shows, keyed by show id. Separate from
    /// `coverURLs` (book covers) only in name — same dictionary shape, kept
    /// distinct so a show id can never collide with a book id in one map.
    @Published public private(set) var showCoverURLs: [String: URL] = [:]

    /// Selected show's episode list (By Show → episode list, c2s.2). Sorted by
    /// `episodeSortOrder` at the call site, not stored pre-sorted, so a live
    /// setting change re-renders without a re-fetch.
    @Published public private(set) var selectedShow: PodcastShow?
    @Published public private(set) var selectedShowEpisodes: [ABSEpisodeDTO] = []
    @Published public private(set) var showDetailState: LoadState = .idle

    /// Recent Episodes: every show's episodes flattened (c2s.2). Populated by
    /// `loadRecentEpisodes`, which fetches each show's detail once.
    @Published public private(set) var recentEpisodes: [PodcastEpisodeEntry] = []
    @Published public private(set) var recentEpisodesState: LoadState = .idle

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
    ///
    /// c2s.3: the same response mixes in podcast episodes — `partition` (pure,
    /// unit-tested) splits them out so `inProgress` (books) keeps behaving
    /// exactly as before and `inProgressEpisodes` is purely additive.
    public func loadInProgress() async {
        guard let items = try? await api.itemsInProgress() else { return }
        let now = Int(Date().timeIntervalSince1970)
        let (books, episodes) = PodcastContinueListening.partition(items: items, updatedAt: now)
        inProgress = books
        // `recentEpisode` carries no progress — hydrate each episode's real
        // progress/resume position from /api/me/progress/{item}/{episode}.
        var hydrated: [PodcastEpisodeEntry] = []
        for entry in episodes {
            let progress = await api.episodeProgress(libraryItemId: entry.showLibraryItemId, episodeId: entry.episode.id)
            hydrated.append(entry.withProgress(progress))
        }
        inProgressEpisodes = hydrated
        await resolveCovers(for: books)
        await resolveShowCovers(for: episodes.map(\.showLibraryItemId))
    }

    /// Maps in-progress DTOs to records, dropping finished/unstarted books.
    /// Pure so the filter/order is unit-testable. Server order is preserved.
    /// Kept for existing callers/tests; `loadInProgress` now routes through
    /// `PodcastContinueListening.partition` so podcast episodes in the same
    /// response don't fall through into the book list.
    static func inProgressBooks(from items: [ABSLibraryItemDTO], updatedAt: Int) -> [Audiobook] {
        PodcastContinueListening.partition(items: items, updatedAt: updatedAt).books
    }

    private func resolveCovers(for books: [Audiobook]) async {
        for book in books {
            if let url = await api.coverURL(itemID: book.id) {
                coverURLs[book.id] = url
            }
        }
    }

    private func resolveShowCovers(for showIDs: [String]) async {
        for id in Set(showIDs) where showCoverURLs[id] == nil {
            if let url = await api.coverURL(itemID: id) {
                showCoverURLs[id] = url
            }
        }
    }

    // MARK: - Podcasts (E3 / c2s.2)

    /// Loads every podcast show across all podcast libraries. Mirrors
    /// `loadBooks`'s shape (fetch libraries, fetch each library's items,
    /// flatten, sort by title) but shows aren't persisted to the local DB —
    /// there's no offline/download story for podcast shows yet.
    public func loadPodcastShows() async {
        guard podcastShowsState != .loading else { return }
        podcastShowsState = .loading
        do {
            let libraries = try await api.podcastLibraries()
            self.podcastLibraries = libraries
            var all: [PodcastShow] = []
            for library in libraries {
                let items = try await api.items(inLibrary: library.id)
                all.append(contentsOf: items.compactMap { PodcastShow(item: $0, libraryIdFallback: library.id) })
            }
            all.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            podcastShows = all
            podcastShowsState = all.isEmpty ? .empty : .loaded
            await resolveShowCovers(for: all.map(\.id))
        } catch let apiErr as AudiobookshelfAPI.APIError {
            podcastShowsState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            podcastShowsState = .error(error.localizedDescription)
        }
    }

    /// Loads one show's full episode list (By Show → episode list, c2s.2).
    /// Episodes are stored in server (newest-first) order; views sort for
    /// display via `PodcastPlaybackContext.sortedEpisodes(_:order:)`.
    public func loadShowDetail(_ show: PodcastShow) async {
        selectedShow = show
        selectedShowEpisodes = []
        showDetailState = .loading
        do {
            let item = try await api.item(id: show.id)
            let episodes = item.episodes()
            selectedShowEpisodes = episodes
            showDetailState = episodes.isEmpty ? .empty : .loaded
        } catch let apiErr as AudiobookshelfAPI.APIError {
            showDetailState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            showDetailState = .error(error.localizedDescription)
        }
    }

    public func resetShowDetail() {
        selectedShow = nil
        selectedShowEpisodes = []
        showDetailState = .idle
    }

    /// Max shows fetched concurrently by `loadRecentEpisodes` (uxc.3). Bounded
    /// rather than "one task per show" — the ABS server may be a Raspberry Pi,
    /// and a library can have dozens of shows.
    static let recentEpisodesConcurrency = 5

    /// Loads every show's episodes and flattens them for "Recent Episodes"
    /// (c2s.2). Requires `podcastShows` to already be loaded (call after
    /// `loadPodcastShows`); fetches each show's detail once via `item(id:)`.
    ///
    /// uxc.3: shows are fetched with bounded concurrency
    /// (`recentEpisodesConcurrency` in flight at a time) instead of one
    /// serial `await` per show — a library of N shows no longer blocks on
    /// N sequential round-trips. Completion order isn't the show order, so
    /// results are gathered with their original index and re-sorted before
    /// `PodcastRecentEpisodes.aggregate` (which folds shows together in the
    /// order given) — see `Self.reordered`.
    public func loadRecentEpisodes(order: PodcastEpisodeOrder) async {
        guard recentEpisodesState != .loading else { return }
        let shows = podcastShows
        guard !shows.isEmpty else {
            recentEpisodesState = .empty
            return
        }
        recentEpisodesState = .loading

        var results: [(index: Int, show: PodcastShow, episodes: [ABSEpisodeDTO])?] =
            Array(repeating: nil, count: shows.count)

        await withTaskGroup(of: (Int, PodcastShow, [ABSEpisodeDTO]?).self) { group in
            var nextIndex = 0

            func addTask(for index: Int) {
                let show = shows[index]
                group.addTask { [api] in
                    let item = try? await api.item(id: show.id)
                    return (index, show, item?.episodes())
                }
            }

            let initialBatch = min(Self.recentEpisodesConcurrency, shows.count)
            for i in 0..<initialBatch {
                addTask(for: i)
                nextIndex = i + 1
            }

            while let (index, show, episodes) = await group.next() {
                if let episodes {
                    results[index] = (index, show, episodes)
                }
                if nextIndex < shows.count {
                    addTask(for: nextIndex)
                    nextIndex += 1
                }
            }
        }

        let pairs = Self.reordered(results)
        let flattened = PodcastRecentEpisodes.aggregate(shows: pairs, order: order)
        recentEpisodes = flattened
        recentEpisodesState = flattened.isEmpty ? .empty : .loaded
        await resolveShowCovers(for: pairs.map(\.show.id))
    }

    /// Reassembles concurrently-fetched per-show results back into their
    /// original (index) order, dropping shows whose fetch failed. Pure —
    /// testable without async/network; the input can arrive in ANY order
    /// (task-group completion order is non-deterministic) and the output must
    /// always match the original show order for `PodcastRecentEpisodes
    /// .aggregate`'s per-show grouping to stay deterministic.
    nonisolated static func reordered(
        _ results: [(index: Int, show: PodcastShow, episodes: [ABSEpisodeDTO])?]
    ) -> [(show: PodcastShow, episodes: [ABSEpisodeDTO])] {
        results
            .compactMap { $0 }
            .sorted { $0.index < $1.index }
            .map { (show: $0.show, episodes: $0.episodes) }
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
        // This /play session is opened only to read audioTracks[] for the offset
        // join — close it on every path (incl. the nil-bail below) so the server
        // doesn't hold an idle session until it reaps (ymf.4).
        defer { Task { await api.closeSession(sessionID: session.id) } }

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

    // MARK: - Podcast episode download (E4 / 6b5.1)

    /// Downloads one episode: builds its 1-file manifest (`AudiobookDownloadRecord.forEpisode`)
    /// and enqueues it via the SAME `DownloadManager.downloadBook` path books use —
    /// an episode has its `ino`/`duration` right on `ABSEpisodeDTO.audioFile`
    /// already, so unlike a book download there's no `/play` session needed just
    /// to join offsets. No-op if the episode has no audio file. `static` (no
    /// view-model instance needed) so download buttons on episode rows can call
    /// it directly with just the `AudiobookshelfAPI` from `ProviderManager`.
    @MainActor
    public static func downloadEpisode(_ episode: ABSEpisodeDTO, show: PodcastShow, using downloadManager: DownloadManager, via api: AudiobookshelfAPI) {
        guard let record = AudiobookDownloadRecord.forEpisode(
            showID: show.id,
            showTitle: show.title,
            episodeID: episode.id,
            episodeTitle: episode.title,
            coverPath: "/api/items/\(show.id)/cover",
            audioFile: episode.audioFile
        ) else { return }

        downloadManager.downloadBook(
            itemID: record.id,
            title: record.title,
            author: record.author,
            coverPath: record.coverPath,
            duration: record.duration,
            files: record.files,
            chapters: record.chapters,
            via: api
        )
    }
}
