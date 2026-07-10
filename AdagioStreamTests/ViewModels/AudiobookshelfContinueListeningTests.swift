import XCTest
@testable import AdagioStream

// 00t — Continue-Listening filter: keep started, not-finished books in server
// order; drop finished and unstarted ones.
// c2s.3 — the same items-in-progress response mixes in podcast episodes;
// `PodcastContinueListening.partition` splits books from episodes.
@MainActor
final class AudiobookshelfContinueListeningTests: XCTestCase {

    private func item(id: String, progress: Double, finished: Bool) -> ABSLibraryItemDTO {
        let json = """
        {
          "id": "\(id)",
          "libraryId": "lib-1",
          "media": { "duration": 100.0, "metadata": { "title": "\(id)" } },
          "userMediaProgress": { "currentTime": 10.0, "progress": \(progress), "isFinished": \(finished) }
        }
        """
        return try! JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(json.utf8))
    }

    /// A podcast-episode-in-progress entry, as ABS represents it: a library
    /// item for the SHOW whose `media.episodes[]` carries exactly the one
    /// recently-played episode (vs. a book item, whose `media.episodes` is
    /// always empty/absent).
    private func episodeItem(showId: String, showTitle: String, episodeId: String, progress: Double, finished: Bool) -> ABSLibraryItemDTO {
        let json = """
        {
          "id": "\(showId)",
          "libraryId": "lib-podcasts",
          "media": {
            "metadata": { "title": "\(showTitle)" },
            "episodes": [
              { "id": "\(episodeId)", "title": "Episode Title", "userMediaProgress": { "currentTime": 5.0, "progress": \(progress), "isFinished": \(finished) } }
            ]
          }
        }
        """
        return try! JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(json.utf8))
    }

    func testKeepsStartedUnfinishedInServerOrder() {
        let items = [
            item(id: "started-a", progress: 0.4, finished: false),
            item(id: "finished", progress: 1.0, finished: true),
            item(id: "unstarted", progress: 0.0, finished: false),
            item(id: "started-b", progress: 0.1, finished: false),
        ]
        let result = AudiobookshelfLibraryViewModel.inProgressBooks(from: items, updatedAt: 1)
        XCTAssertEqual(result.map(\.id), ["started-a", "started-b"])
    }

    func testEmptyWhenNothingInProgress() {
        let items = [item(id: "finished", progress: 1.0, finished: true)]
        XCTAssertTrue(AudiobookshelfLibraryViewModel.inProgressBooks(from: items, updatedAt: 1).isEmpty)
    }

    // MARK: - c2s.3: partition mixed books + podcast episodes

    func testPartitionSeparatesBooksFromEpisodes() {
        let items = [
            item(id: "book-a", progress: 0.4, finished: false),
            episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1", progress: 0.2, finished: false),
            item(id: "book-b", progress: 0.1, finished: false),
            episodeItem(showId: "show-b", showTitle: "Show B", episodeId: "ep-2", progress: 0.9, finished: false),
        ]
        let (books, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        XCTAssertEqual(books.map(\.id), ["book-a", "book-b"])
        XCTAssertEqual(episodes.map(\.episode.id), ["ep-1", "ep-2"])
        XCTAssertEqual(episodes.map(\.showLibraryItemId), ["show-a", "show-b"])
        XCTAssertEqual(episodes.map(\.showTitle), ["Show A", "Show B"])
    }

    func testPartitionPreservesServerOrderAcrossBooksAndEpisodes() {
        let items = [
            episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1", progress: 0.2, finished: false),
            item(id: "book-a", progress: 0.4, finished: false),
        ]
        let (books, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        XCTAssertEqual(books.map(\.id), ["book-a"])
        XCTAssertEqual(episodes.map(\.episode.id), ["ep-1"])
    }

    func testPartitionDropsFinishedBooksButBookFilterDoesNotApplyToEpisodes() {
        // Books still get the started/not-finished filter (unchanged from
        // `inProgressBooks`). Episodes are passed through as-is — the server
        // items-in-progress endpoint only returns started episodes, so no
        // client-side re-filter is applied to them.
        let items = [
            item(id: "finished-book", progress: 1.0, finished: true),
            episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1", progress: 0.2, finished: false),
        ]
        let (books, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        XCTAssertTrue(books.isEmpty)
        XCTAssertEqual(episodes.map(\.episode.id), ["ep-1"])
    }

    func testPartitionEmptyWhenNothingInProgress() {
        let (books, episodes) = PodcastContinueListening.partition(items: [], updatedAt: 1)
        XCTAssertTrue(books.isEmpty)
        XCTAssertTrue(episodes.isEmpty)
    }
}
