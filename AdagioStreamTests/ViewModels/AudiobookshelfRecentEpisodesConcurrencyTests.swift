// uxc.3 — loadRecentEpisodes moved from a serial per-show await loop to a
// bounded-concurrency withTaskGroup fetch. Task-group completion order is
// non-deterministic, so `AudiobookshelfLibraryViewModel.reordered` re-sorts
// gathered results back into the original show order before
// `PodcastRecentEpisodes.aggregate` (which folds shows together in the order
// given). These tests cover that pure reordering seam directly — no
// async/network involved.

import XCTest
@testable import AdagioStream

final class AudiobookshelfRecentEpisodesConcurrencyTests: XCTestCase {

    private func show(_ id: String) -> PodcastShow {
        PodcastShow(id: id, libraryId: "lib-1", title: id, author: nil)
    }

    private func episode(_ id: String) -> ABSEpisodeDTO {
        ABSEpisodeDTO(id: id, title: id, duration: nil)
    }

    func testReorderedRestoresOriginalIndexOrderRegardlessOfCompletionOrder() {
        // Simulates 3 shows whose network fetches completed out of order
        // (show 2 finished first, then 0, then 1).
        let results: [(index: Int, show: PodcastShow, episodes: [ABSEpisodeDTO])?] = [
            (index: 0, show: show("show-a"), episodes: [episode("a1")]),
            (index: 1, show: show("show-b"), episodes: [episode("b1")]),
            (index: 2, show: show("show-c"), episodes: [episode("c1")]),
        ].shuffled()

        let reordered = AudiobookshelfLibraryViewModel.reordered(results)

        XCTAssertEqual(reordered.map { $0.show.id }, ["show-a", "show-b", "show-c"])
    }

    func testReorderedDropsFailedFetchesButKeepsOthersInOrder() {
        // A `nil` slot represents a show whose `item(id:)` fetch failed
        // (`try?` swallowed it) — must be skipped, not crash or leave a gap
        // that shifts the remaining order.
        let results: [(index: Int, show: PodcastShow, episodes: [ABSEpisodeDTO])?] = [
            (index: 0, show: show("show-a"), episodes: [episode("a1")]),
            nil, // show-b's fetch failed
            (index: 2, show: show("show-c"), episodes: [episode("c1")]),
        ]

        let reordered = AudiobookshelfLibraryViewModel.reordered(results)

        XCTAssertEqual(reordered.map { $0.show.id }, ["show-a", "show-c"])
    }

    func testReorderedEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(AudiobookshelfLibraryViewModel.reordered([]).isEmpty)
    }

    func testReorderedAllFailedProducesEmptyOutput() {
        let results: [(index: Int, show: PodcastShow, episodes: [ABSEpisodeDTO])?] = [nil, nil, nil]
        XCTAssertTrue(AudiobookshelfLibraryViewModel.reordered(results).isEmpty)
    }

    // MARK: - Integration: final aggregate stays deterministic under any gather order

    func testAggregateOverReorderedResultsMatchesShowOrderRegardlessOfGatherOrder() {
        let unordered: [(index: Int, show: PodcastShow, episodes: [ABSEpisodeDTO])?] = [
            (index: 2, show: show("show-c"), episodes: [episode("c1")]),
            (index: 0, show: show("show-a"), episodes: [episode("a1")]),
            (index: 1, show: show("show-b"), episodes: [episode("b1")]),
        ]

        let pairs = AudiobookshelfLibraryViewModel.reordered(unordered)
        let flattened = PodcastRecentEpisodes.aggregate(shows: pairs, order: .newestFirst)

        XCTAssertEqual(flattened.map(\.showLibraryItemId), ["show-a", "show-b", "show-c"])
    }
}
