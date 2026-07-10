import XCTest
@testable import AdagioStream

// Podcast E2 / 72i.2 — whole-show auto-play next-episode selection. Pure
// function, no VLC/network — the smallest checks that fail if newest/oldest
// ordering or end-of-show detection breaks.

final class PodcastPlaybackContextTests: XCTestCase {

    /// Decodes a minimal episode list JSON. `ABSEpisodeDTO`'s only init is
    /// `Decodable`, matching every other DTO in this file — same convention as
    /// `AudiobookshelfModelsTests`.
    private func episodes(ids: [String]) -> [ABSEpisodeDTO] {
        let entries = ids.map { "{\"id\": \"\($0)\", \"title\": \"Episode \($0)\"}" }.joined(separator: ",")
        let json = "[\(entries)]"
        return try! JSONDecoder().decode([ABSEpisodeDTO].self, from: Data(json.utf8))
    }

    // Server order is newest-first by ABS convention: e3, e2, e1 (e3 newest).
    private func makeEpisodes() -> [ABSEpisodeDTO] {
        episodes(ids: ["e3", "e2", "e1"])
    }

    // MARK: - Newest-first (default, walks server order as-is)

    func testNewestFirstAdvancesToNextInServerOrder() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e3", order: .newestFirst)
        XCTAssertEqual(next?.id, "e2")
    }

    func testNewestFirstStopsAtOldestEpisode() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e1", order: .newestFirst)
        XCTAssertNil(next, "e1 is last in newest-first order — show has ended")
    }

    // MARK: - Oldest-first (reversed traversal)

    func testOldestFirstAdvancesFromOldestToNewer() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e1", order: .oldestFirst)
        XCTAssertEqual(next?.id, "e2")
    }

    func testOldestFirstStopsAtNewestEpisode() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e3", order: .oldestFirst)
        XCTAssertNil(next, "e3 is last in oldest-first order — show has ended")
    }

    // MARK: - Edge cases

    func testUnknownCurrentEpisodeReturnsNil() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "missing", order: .newestFirst)
        XCTAssertNil(next)
    }

    func testSingleEpisodeShowHasNoNext() {
        let next = PodcastPlaybackContext.nextEpisode(in: episodes(ids: ["only"]), after: "only", order: .newestFirst)
        XCTAssertNil(next)
    }

    func testEmptyShowReturnsNil() {
        let next = PodcastPlaybackContext.nextEpisode(in: [], after: "e1", order: .newestFirst)
        XCTAssertNil(next)
    }

    // MARK: - Instance convenience mirrors the static helper

    func testContextInstanceMethodMirrorsStaticHelper() {
        let context = PodcastPlaybackContext(libraryItemId: "show-1", showTitle: "The Show", episodes: makeEpisodes(), order: .newestFirst)
        XCTAssertEqual(context.nextEpisode(after: "e3")?.id, "e2")
    }
}
