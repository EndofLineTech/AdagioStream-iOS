import XCTest
@testable import AdagioStream

// Podcast E2 review fix — root cause: for a podcast display record `book.id` is
// the EPISODE id and the show/library-item id lives in `book.libraryItemId`.
// `AudiobookSession.progressKey` must key a podcast under the SHOW id, not the
// episode id; a book (where `libraryItemId == id`) must stay keyed by `book.id`.
//
// Pure value assertions only — `AudiobookSession.init` is fully synchronous and
// no method here touches the network, so nothing can hang the suite.
final class AudiobookProgressKeyTests: XCTestCase {

    /// A session whose `book`/`kind` are what we assert against. `api`/`timeline`
    /// are inert scaffolding required by the init; `progressKey` reads neither.
    private func makeSession(book: Audiobook, kind: AudiobookSessionKind) -> AudiobookSession {
        let auth = AudiobookshelfAuth(
            host: URL(string: "https://abs.example")!,
            username: "u", password: "p", providerID: "PID",
            loadTokens: { _ in nil }, saveTokens: { _, _ in }, clearTokens: { _ in }
        )
        let api = AudiobookshelfAPI(host: URL(string: "https://abs.example")!, auth: auth)
        let file = AudiobookTimeline.File(index: 0, startOffset: 0, duration: 100, contentPath: "/f")
        let timeline = AudiobookTimeline(files: [file])
        return AudiobookSession(
            book: book, sessionID: "S", timeline: timeline, api: api,
            startFile: file, startGlobalTime: 0, kind: kind
        )
    }

    private func book(id: String, libraryItemId: String) -> Audiobook {
        Audiobook(id: id, libraryItemId: libraryItemId, libraryId: "L", title: "T", updatedAt: 0)
    }

    /// Podcast: episode id != show id → key uses the SHOW id for `libraryItemId`
    /// and the episode id for `episodeId`. (Finding 2 — latent progressKey bug.)
    func testPodcastProgressKeyUsesShowIdNotEpisodeId() {
        let record = book(id: "EPISODE_ID", libraryItemId: "SHOW_ID")
        let session = makeSession(book: record, kind: .podcast(
            episodeId: "EPISODE_ID",
            context: PodcastPlaybackContext(libraryItemId: "SHOW_ID", showTitle: "Show", episodes: [])
        ))
        XCTAssertEqual(session.progressKey.libraryItemId, "SHOW_ID")
        XCTAssertEqual(session.progressKey.episodeId, "EPISODE_ID")
    }

    /// Book: `libraryItemId == id` so the key stays `book.id` and has no episode.
    func testBookProgressKeyStaysBookId() {
        let record = book(id: "BOOK_ID", libraryItemId: "BOOK_ID")
        let session = makeSession(book: record, kind: .book)
        XCTAssertEqual(session.progressKey.libraryItemId, "BOOK_ID")
        XCTAssertNil(session.progressKey.episodeId)
    }
}
