import XCTest
@testable import AdagioStream

// Podcast E3 / c2s.2, c2s.4 — episode sort-order application and
// Recent-Episodes cross-show aggregation. Pure functions, no VLC/network —
// the smallest checks that fail if newest/oldest ordering breaks.

final class PodcastEpisodeSortingTests: XCTestCase {

    private func episodes(ids: [String]) -> [ABSEpisodeDTO] {
        let entries = ids.map { "{\"id\": \"\($0)\", \"title\": \"Episode \($0)\"}" }.joined(separator: ",")
        let json = "[\(entries)]"
        return try! JSONDecoder().decode([ABSEpisodeDTO].self, from: Data(json.utf8))
    }

    // Server order is newest-first by ABS convention: e3, e2, e1 (e3 newest).
    private func makeEpisodes() -> [ABSEpisodeDTO] {
        episodes(ids: ["e3", "e2", "e1"])
    }

    // MARK: - sortedEpisodes: single-show episode-list order (c2s.2, By Show + Recent Episodes)

    func testSortedEpisodesNewestFirstPreservesServerOrder() {
        let sorted = PodcastPlaybackContext.sortedEpisodes(makeEpisodes(), order: .newestFirst)
        XCTAssertEqual(sorted.map(\.id), ["e3", "e2", "e1"])
    }

    func testSortedEpisodesOldestFirstReversesServerOrder() {
        let sorted = PodcastPlaybackContext.sortedEpisodes(makeEpisodes(), order: .oldestFirst)
        XCTAssertEqual(sorted.map(\.id), ["e1", "e2", "e3"])
    }

    func testSortedEpisodesEmptyListStaysEmpty() {
        XCTAssertTrue(PodcastPlaybackContext.sortedEpisodes([], order: .newestFirst).isEmpty)
        XCTAssertTrue(PodcastPlaybackContext.sortedEpisodes([], order: .oldestFirst).isEmpty)
    }

    func testSortedEpisodesSingleEpisodeUnaffectedByOrder() {
        let single = episodes(ids: ["only"])
        XCTAssertEqual(PodcastPlaybackContext.sortedEpisodes(single, order: .newestFirst).map(\.id), ["only"])
        XCTAssertEqual(PodcastPlaybackContext.sortedEpisodes(single, order: .oldestFirst).map(\.id), ["only"])
    }

    // MARK: - PodcastRecentEpisodes.aggregate: cross-show flattening (c2s.2 Recent Episodes)

    private func show(id: String, title: String) -> PodcastShow {
        PodcastShow(id: id, libraryId: "lib-1", title: title, author: nil)
    }

    func testAggregateFlattensShowsInGivenOrderNewestFirst() {
        let showA = show(id: "show-a", title: "Show A")
        let showB = show(id: "show-b", title: "Show B")
        let pairs: [(show: PodcastShow, episodes: [ABSEpisodeDTO])] = [
            (showA, episodes(ids: ["a2", "a1"])),   // a2 newest
            (showB, episodes(ids: ["b2", "b1"])),   // b2 newest
        ]
        let result = PodcastRecentEpisodes.aggregate(shows: pairs, order: .newestFirst)
        XCTAssertEqual(result.map(\.episode.id), ["a2", "a1", "b2", "b1"])
        XCTAssertEqual(result.map(\.showLibraryItemId), ["show-a", "show-a", "show-b", "show-b"])
    }

    func testAggregateReversesEachShowsEpisodesOldestFirst() {
        let showA = show(id: "show-a", title: "Show A")
        let pairs: [(show: PodcastShow, episodes: [ABSEpisodeDTO])] = [
            (showA, episodes(ids: ["a2", "a1"])),
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
            (full, episodes(ids: ["f1"])),
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
