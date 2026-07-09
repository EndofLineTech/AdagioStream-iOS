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

    // MARK: - Book detail (chapters)

    @Published public private(set) var selectedBook: Audiobook?
    @Published public private(set) var chapters: [AudiobookChapter] = []
    @Published public private(set) var detailState: LoadState = .idle

    // MARK: - Cover URLs (resolved async — ABS covers are token-in-query URLs)

    /// Resolved cover URLs keyed by book id. Populated as `loadBooks` completes.
    @Published public private(set) var coverURLs: [String: URL] = [:]

    private let api: AudiobookshelfAPI

    public init(api: AudiobookshelfAPI) {
        self.api = api
    }

    /// Exposed so views can start playback via `AudioPlayerService.playAudiobook`.
    public var audiobookshelfAPI: AudiobookshelfAPI { api }

    // MARK: - Load: all books across all book libraries

    public func loadBooks() async {
        guard booksState != .loading else { return }
        booksState = .loading
        do {
            let libraries = try await api.bookLibraries()
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
            await resolveCovers(for: all)
        } catch let apiErr as AudiobookshelfAPI.APIError {
            booksState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            booksState = .error(error.localizedDescription)
        }
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
}
