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

    /// A podcast-episode-in-progress entry in the REAL ABS shape that
    /// `GET /api/me/items-in-progress` sends: a MINIFIED show item (`numEpisodes`,
    /// NO `media.episodes[]`) with the played episode under a TOP-LEVEL
    /// `recentEpisode` field. Critically, `recentEpisode` carries NO
    /// `userMediaProgress` — ABS's `PodcastEpisode.toOldJSON` omits it, so
    /// progress must be hydrated separately (see the hydration test below).
    private func episodeItem(showId: String, showTitle: String, episodeId: String) -> ABSLibraryItemDTO {
        let json = """
        {
          "id": "\(showId)",
          "libraryId": "lib-podcasts",
          "media": {
            "metadata": { "title": "\(showTitle)" },
            "numEpisodes": 12
          },
          "recentEpisode": {
            "id": "\(episodeId)", "title": "Episode Title"
          }
        }
        """
        return try! JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(json.utf8))
    }

    /// A book item that (like a podcast show) reports `numEpisodes > 0` but has
    /// NO `recentEpisode` — the negative case that MUST classify as a book, not
    /// an episode. Guards against the old episode-count heuristic regressing.
    private func bookItemWithEpisodeCount(id: String, progress: Double, finished: Bool) -> ABSLibraryItemDTO {
        let json = """
        {
          "id": "\(id)",
          "libraryId": "lib-1",
          "media": { "duration": 100.0, "metadata": { "title": "\(id)" }, "numEpisodes": 3 },
          "userMediaProgress": { "currentTime": 10.0, "progress": \(progress), "isFinished": \(finished) }
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
            episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1"),
            item(id: "book-b", progress: 0.1, finished: false),
            episodeItem(showId: "show-b", showTitle: "Show B", episodeId: "ep-2"),
        ]
        let (books, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        XCTAssertEqual(books.map(\.id), ["book-a", "book-b"])
        XCTAssertEqual(episodes.map(\.episode.id), ["ep-1", "ep-2"])
        XCTAssertEqual(episodes.map(\.showLibraryItemId), ["show-a", "show-b"])
        XCTAssertEqual(episodes.map(\.showTitle), ["Show A", "Show B"])
    }

    func testPartitionPreservesServerOrderAcrossBooksAndEpisodes() {
        let items = [
            episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1"),
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
            episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1"),
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

    /// Negative case for the discriminator: a book that reports `numEpisodes > 0`
    /// but has NO `recentEpisode` MUST classify as a book. `recentEpisode`
    /// presence — not an episode count — is the signal.
    func testPartitionClassifiesBookWithEpisodeCountAndNoRecentEpisodeAsBook() {
        let items = [bookItemWithEpisodeCount(id: "counted-book", progress: 0.3, finished: false)]
        let (books, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        XCTAssertEqual(books.map(\.id), ["counted-book"])
        XCTAssertTrue(episodes.isEmpty)
    }

    /// The real server shape carries NO progress in `recentEpisode`, so a
    /// freshly-partitioned episode entry reads as unplayed (0 / no resume time)
    /// until progress is hydrated. Guards against re-introducing the false
    /// assumption that `recentEpisode.userMediaProgress` exists.
    func testPartitionedEpisodeHasNoProgressUntilHydrated() {
        let items = [episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1")]
        let (_, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        XCTAssertEqual(episodes.first?.progress, 0)
        XCTAssertNil(episodes.first?.resumeTime)
        XCTAssertTrue(episodes.first?.isUnplayed ?? false)
    }

    /// The hydration merge (`PodcastEpisodeEntry.withProgress`) — the pure seam
    /// `loadInProgress` fills from `GET /api/me/progress/{item}/{episode}`.
    /// Progress fraction, finished state, and the resume position all come from
    /// the fetched record, not the (progress-less) `recentEpisode`.
    func testWithProgressHydratesProgressAndResumeTime() {
        let items = [episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1")]
        let (_, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        let fetched = try! JSONDecoder().decode(
            ABSMediaProgressDTO.self,
            from: Data(#"{ "currentTime": 42.0, "progress": 0.6, "isFinished": false }"#.utf8)
        )
        let hydrated = episodes.first!.withProgress(fetched)
        XCTAssertEqual(hydrated.progress, 0.6)
        XCTAssertEqual(hydrated.isFinished, false)
        XCTAssertEqual(hydrated.resumeTime, 42.0)
        XCTAssertFalse(hydrated.isUnplayed)
    }

    /// A 404 (episode never started) hydrates as `nil` → still unplayed, no
    /// fabricated resume time.
    func testWithProgressNilKeepsEntryUnplayed() {
        let items = [episodeItem(showId: "show-a", showTitle: "Show A", episodeId: "ep-1")]
        let (_, episodes) = PodcastContinueListening.partition(items: items, updatedAt: 1)
        let hydrated = episodes.first!.withProgress(nil)
        XCTAssertEqual(hydrated.progress, 0)
        XCTAssertNil(hydrated.resumeTime)
        XCTAssertTrue(hydrated.isUnplayed)
    }
}
