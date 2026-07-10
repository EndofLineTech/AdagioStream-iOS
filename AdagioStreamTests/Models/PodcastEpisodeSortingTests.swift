import XCTest
@testable import AdagioStream

// Podcast E3 / c2s.2, c2s.4 — episode sort-order application and
// Recent-Episodes cross-show aggregation. Pure functions, no VLC/network —
// the smallest checks that fail if newest/oldest ordering breaks.

final class PodcastEpisodeSortingTests: XCTestCase {

    /// Builds episodes from `(id, pubDate)` pairs. `pubDate == nil` emits an
    /// episode with no `pubDate` field (undated), to exercise the last-stable
    /// fallback. `pubDate` strings are RFC-2822, the shape ABS ships.
    private func episodes(_ pairs: [(id: String, pubDate: String?)]) -> [ABSEpisodeDTO] {
        let entries = pairs.map { pair -> String in
            if let date = pair.pubDate {
                return "{\"id\": \"\(pair.id)\", \"title\": \"Episode \(pair.id)\", \"pubDate\": \"\(date)\"}"
            }
            return "{\"id\": \"\(pair.id)\", \"title\": \"Episode \(pair.id)\"}"
        }.joined(separator: ",")
        return try! JSONDecoder().decode([ABSEpisodeDTO].self, from: Data("[\(entries)]".utf8))
    }

    // e3 newest, e1 oldest — deliberately given in NON-chronological WIRE order
    // (e1, e3, e2) so a test that merely reverses wire order would fail; only an
    // explicit pubDate sort produces the asserted chronological result.
    private func makeEpisodes() -> [ABSEpisodeDTO] {
        episodes([
            (id: "e1", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT"),
            (id: "e3", pubDate: "Wed, 03 Jan 2024 00:00:00 GMT"),
            (id: "e2", pubDate: "Tue, 02 Jan 2024 00:00:00 GMT"),
        ])
    }

    // MARK: - sortedEpisodes: explicit pubDate order (c2s.2/c2s.4, By Show + Recent Episodes)

    func testSortedEpisodesNewestFirstSortsDescendingByPubDate() {
        let sorted = PodcastPlaybackContext.sortedEpisodes(makeEpisodes(), order: .newestFirst)
        XCTAssertEqual(sorted.map(\.id), ["e3", "e2", "e1"])
    }

    func testSortedEpisodesOldestFirstSortsAscendingByPubDate() {
        let sorted = PodcastPlaybackContext.sortedEpisodes(makeEpisodes(), order: .oldestFirst)
        XCTAssertEqual(sorted.map(\.id), ["e1", "e2", "e3"])
    }

    func testSortedEpisodesUndatedSortLastStablyRegardlessOfOrder() {
        let mixed = episodes([
            (id: "undated-1", pubDate: nil),
            (id: "dated-old", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT"),
            (id: "undated-2", pubDate: nil),
            (id: "dated-new", pubDate: "Fri, 05 Jan 2024 00:00:00 GMT"),
        ])
        // Dated episodes lead in their chosen order; undated trail in wire order.
        XCTAssertEqual(
            PodcastPlaybackContext.sortedEpisodes(mixed, order: .newestFirst).map(\.id),
            ["dated-new", "dated-old", "undated-1", "undated-2"]
        )
        XCTAssertEqual(
            PodcastPlaybackContext.sortedEpisodes(mixed, order: .oldestFirst).map(\.id),
            ["dated-old", "dated-new", "undated-1", "undated-2"]
        )
    }

    func testSortedEpisodesEmptyListStaysEmpty() {
        XCTAssertTrue(PodcastPlaybackContext.sortedEpisodes([], order: .newestFirst).isEmpty)
        XCTAssertTrue(PodcastPlaybackContext.sortedEpisodes([], order: .oldestFirst).isEmpty)
    }

    func testSortedEpisodesSingleEpisodeUnaffectedByOrder() {
        let single = episodes([(id: "only", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT")])
        XCTAssertEqual(PodcastPlaybackContext.sortedEpisodes(single, order: .newestFirst).map(\.id), ["only"])
        XCTAssertEqual(PodcastPlaybackContext.sortedEpisodes(single, order: .oldestFirst).map(\.id), ["only"])
    }

    // MARK: - PodcastRecentEpisodes.aggregate: cross-show flattening (c2s.2 Recent Episodes)

    private func show(id: String, title: String) -> PodcastShow {
        PodcastShow(id: id, libraryId: "lib-1", title: title, author: nil)
    }

    func testAggregateFlattensEachShowInChosenOrderNewestFirst() {
        let showA = show(id: "show-a", title: "Show A")
        let showB = show(id: "show-b", title: "Show B")
        let pairs: [(show: PodcastShow, episodes: [ABSEpisodeDTO])] = [
            (showA, episodes([(id: "a1", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT"), (id: "a2", pubDate: "Tue, 02 Jan 2024 00:00:00 GMT")])),
            (showB, episodes([(id: "b1", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT"), (id: "b2", pubDate: "Tue, 02 Jan 2024 00:00:00 GMT")])),
        ]
        let result = PodcastRecentEpisodes.aggregate(shows: pairs, order: .newestFirst)
        // Each show sorted newest-first (a2 before a1); shows folded in given order.
        XCTAssertEqual(result.map(\.episode.id), ["a2", "a1", "b2", "b1"])
        XCTAssertEqual(result.map(\.showLibraryItemId), ["show-a", "show-a", "show-b", "show-b"])
    }

    func testAggregateSortsEachShowsEpisodesOldestFirst() {
        let showA = show(id: "show-a", title: "Show A")
        let pairs: [(show: PodcastShow, episodes: [ABSEpisodeDTO])] = [
            (showA, episodes([(id: "a2", pubDate: "Tue, 02 Jan 2024 00:00:00 GMT"), (id: "a1", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT")])),
        ]
        let result = PodcastRecentEpisodes.aggregate(shows: pairs, order: .oldestFirst)
        XCTAssertEqual(result.map(\.episode.id), ["a1", "a2"])
    }

    func testAggregateEmptyShowsProducesEmptyList() {
        XCTAssertTrue(PodcastRecentEpisodes.aggregate(shows: [], order: .newestFirst).isEmpty)
    }

    func testAggregateSkipsShowWithNoEpisodesButKeepsOthers() {
        let empty = show(id: "empty-show", title: "Empty")
        let full = show(id: "full-show", title: "Full")
        let pairs: [(show: PodcastShow, episodes: [ABSEpisodeDTO])] = [
            (empty, []),
            (full, episodes([(id: "f1", pubDate: "Mon, 01 Jan 2024 00:00:00 GMT")])),
        ]
        let result = PodcastRecentEpisodes.aggregate(shows: pairs, order: .newestFirst)
        XCTAssertEqual(result.map(\.episode.id), ["f1"])
    }

    // MARK: - PodcastEpisodeEntry progress/unplayed derivation (c2s.2 unplayed badge)

    private func episodeWithProgress(id: String, progress: Double?, finished: Bool?) -> ABSEpisodeDTO {
        let progressJSON: String
        if let progress {
            progressJSON = "\"userMediaProgress\": {\"progress\": \(progress), \"isFinished\": \(finished ?? false)}"
        } else {
            progressJSON = "\"userMediaProgress\": null"
        }
        let json = "{\"id\": \"\(id)\", \"title\": \"Episode\", \(progressJSON)}"
        return try! JSONDecoder().decode(ABSEpisodeDTO.self, from: Data(json.utf8))
    }

    func testUnplayedWhenNoProgress() {
        let entry = PodcastEpisodeEntry(episode: episodeWithProgress(id: "e1", progress: nil, finished: nil), showLibraryItemId: "s1", showTitle: nil)
        XCTAssertTrue(entry.isUnplayed)
        XCTAssertFalse(entry.isFinished)
    }

    func testNotUnplayedWhenInProgress() {
        let entry = PodcastEpisodeEntry(episode: episodeWithProgress(id: "e1", progress: 0.5, finished: false), showLibraryItemId: "s1", showTitle: nil)
        XCTAssertFalse(entry.isUnplayed)
        XCTAssertFalse(entry.isFinished)
    }

    func testNotUnplayedWhenFinished() {
        let entry = PodcastEpisodeEntry(episode: episodeWithProgress(id: "e1", progress: 1.0, finished: true), showLibraryItemId: "s1", showTitle: nil)
        XCTAssertFalse(entry.isUnplayed)
        XCTAssertTrue(entry.isFinished)
    }
}
