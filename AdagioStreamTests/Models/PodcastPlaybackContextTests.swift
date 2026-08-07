import XCTest
@testable import AdagioStream

// Podcast whole-show auto-play next-episode selection (beads_mobilemusic-5aj.2).
// Pure function, no VLC/network — the smallest checks that fail if a policy's
// selection logic regresses. Replaces the pre-5aj.2 `nextEpisode(after:)`,
// which always walked `sortedEpisodes` one slot forward — under the default
// newest-first display order that silently auto-played the next OLDER
// (already-heard) episode. That's the reported TestFlight bug; see
// `testRegressionFinishingNewestEpisodeInNewestFirstListStops` below.

final class PodcastPlaybackContextTests: XCTestCase {

    /// Decodes a minimal episode list JSON. `ABSEpisodeDTO`'s only init is
    /// `Decodable`, matching every other DTO in this file — same convention as
    /// `AudiobookshelfModelsTests`.
    ///
    /// Fixtures carry real RFC-2822 `pubDate` values keyed off the trailing
    /// digit: e1 oldest … e3/e4/e5 progressively newer.
    private func episodes(ids: [String]) -> [ABSEpisodeDTO] {
        let entries = ids.map { id -> String in
            // Map a trailing digit N to 2024-01-0N; ids without one stay undated.
            if let last = id.last, let day = last.wholeNumberValue, (1...9).contains(day) {
                let date = String(format: "Mon, 0%d Jan 2024 00:00:00 GMT", day)
                return "{\"id\": \"\(id)\", \"title\": \"Episode \(id)\", \"pubDate\": \"\(date)\"}"
            }
            return "{\"id\": \"\(id)\", \"title\": \"Episode \(id)\"}"
        }.joined(separator: ",")
        return try! JSONDecoder().decode([ABSEpisodeDTO].self, from: Data("[\(entries)]".utf8))
    }

    // e3 newest, e1 oldest (dates from the trailing digit above). Fixtures are
    // stored in SERVER (newest-first-ish arbitrary) wire order deliberately —
    // `nextEpisode` must not depend on caller-supplied ordering.
    private func makeEpisodes() -> [ABSEpisodeDTO] {
        episodes(ids: ["e3", "e2", "e1"])
    }

    private func noneFinished(_ id: String) -> Bool { false }

    // MARK: - .stop policy

    func testStopPolicyAlwaysReturnsNilRegardlessOfEpisodesOrPosition() {
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e1", order: .newestFirst, behavior: .stop, isFinished: noneFinished))
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e2", order: .oldestFirst, behavior: .stop, isFinished: noneFinished))
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e3", order: .newestFirst, behavior: .stop, isFinished: noneFinished))
    }

    // MARK: - .nextUnplayed policy (the default; fixes the reported bug)

    func testNextUnplayedPicksClosestStrictlyNewerUnplayedEpisode() {
        // From e1 (oldest), the closest strictly-newer episode is e2.
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e1", order: .newestFirst, behavior: .nextUnplayed, isFinished: noneFinished)
        XCTAssertEqual(next?.id, "e2")
    }

    func testNextUnplayedSkipsFinishedEpisodesToFindTheNextUnplayedOne() {
        let episodes = self.episodes(ids: ["e1", "e2", "e3", "e4"])
        let finished: Set<String> = ["e2", "e3"]
        let next = PodcastPlaybackContext.nextEpisode(in: episodes, after: "e1", order: .newestFirst, behavior: .nextUnplayed, isFinished: { finished.contains($0) })
        XCTAssertEqual(next?.id, "e4", "e2 and e3 are already finished — the closest unplayed newer episode is e4")
    }

    func testNextUnplayedReturnsNilAtTheNewestEpisode() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e3", order: .newestFirst, behavior: .nextUnplayed, isFinished: noneFinished)
        XCTAssertNil(next, "e3 is the newest episode — nothing newer exists, so auto-play must stop")
    }

    func testNextUnplayedReturnsNilWhenEveryNewerEpisodeIsFinished() {
        let episodes = self.episodes(ids: ["e1", "e2", "e3"])
        let finished: Set<String> = ["e2", "e3"]
        let next = PodcastPlaybackContext.nextEpisode(in: episodes, after: "e1", order: .newestFirst, behavior: .nextUnplayed, isFinished: { finished.contains($0) })
        XCTAssertNil(next)
    }

    func testNextUnplayedNeverConsidersUndatedEpisodesAsCandidates() {
        let episodes = self.episodes(ids: ["e1", "undated", "e2"])
        let next = PodcastPlaybackContext.nextEpisode(in: episodes, after: "e1", order: .newestFirst, behavior: .nextUnplayed, isFinished: noneFinished)
        XCTAssertEqual(next?.id, "e2")
    }

    // MARK: - .continueInSortOrder policy

    func testContinueInSortOrderNewestFirstAdvancesToNextUnfinishedInServerOrder() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e3", order: .newestFirst, behavior: .continueInSortOrder, isFinished: noneFinished)
        XCTAssertEqual(next?.id, "e2")
    }

    func testContinueInSortOrderNewestFirstSkipsFinishedEpisodes() {
        let episodes = self.episodes(ids: ["e4", "e3", "e2", "e1"])
        let finished: Set<String> = ["e3"]
        let next = PodcastPlaybackContext.nextEpisode(in: episodes, after: "e4", order: .newestFirst, behavior: .continueInSortOrder, isFinished: { finished.contains($0) })
        XCTAssertEqual(next?.id, "e2", "e3 is finished — walk continues to e2")
    }

    func testContinueInSortOrderNewestFirstStopsAtOldestEpisode() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e1", order: .newestFirst, behavior: .continueInSortOrder, isFinished: noneFinished)
        XCTAssertNil(next, "e1 is last in newest-first order — show has ended")
    }

    func testContinueInSortOrderOldestFirstAdvancesFromOldestToNewer() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e1", order: .oldestFirst, behavior: .continueInSortOrder, isFinished: noneFinished)
        XCTAssertEqual(next?.id, "e2")
    }

    func testContinueInSortOrderOldestFirstStopsAtNewestEpisode() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "e3", order: .oldestFirst, behavior: .continueInSortOrder, isFinished: noneFinished)
        XCTAssertNil(next, "e3 is last in oldest-first order — show has ended")
    }

    func testContinueInSortOrderReturnsNilWhenAllRemainingEpisodesAreFinished() {
        let episodes = self.episodes(ids: ["e3", "e2", "e1"])
        let finished: Set<String> = ["e2", "e1"]
        let next = PodcastPlaybackContext.nextEpisode(in: episodes, after: "e3", order: .newestFirst, behavior: .continueInSortOrder, isFinished: { finished.contains($0) })
        XCTAssertNil(next)
    }

    // MARK: - Edge cases (apply to any non-.stop policy)

    func testUnknownCurrentEpisodeReturnsNilForNextUnplayed() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "missing", order: .newestFirst, behavior: .nextUnplayed, isFinished: noneFinished)
        XCTAssertNil(next)
    }

    func testUnknownCurrentEpisodeReturnsNilForContinueInSortOrder() {
        let next = PodcastPlaybackContext.nextEpisode(in: makeEpisodes(), after: "missing", order: .newestFirst, behavior: .continueInSortOrder, isFinished: noneFinished)
        XCTAssertNil(next)
    }

    func testSingleEpisodeShowHasNoNextUnderAnyPolicy() {
        let only = episodes(ids: ["only"])
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: only, after: "only", order: .newestFirst, behavior: .nextUnplayed, isFinished: noneFinished))
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: only, after: "only", order: .newestFirst, behavior: .continueInSortOrder, isFinished: noneFinished))
    }

    func testEmptyShowReturnsNilUnderAnyPolicy() {
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: [], after: "e1", order: .newestFirst, behavior: .nextUnplayed, isFinished: noneFinished))
        XCTAssertNil(PodcastPlaybackContext.nextEpisode(in: [], after: "e1", order: .newestFirst, behavior: .continueInSortOrder, isFinished: noneFinished))
    }

    // MARK: - Instance convenience mirrors the static helper

    func testContextInstanceMethodMirrorsStaticHelper() {
        let context = PodcastPlaybackContext(libraryItemId: "show-1", showTitle: "The Show", episodes: makeEpisodes(), order: .newestFirst)
        XCTAssertEqual(context.nextEpisode(after: "e1", behavior: .nextUnplayed, isFinished: noneFinished)?.id, "e2")
    }

    // MARK: - Regression test for the reported TestFlight bug (beads_mobilemusic-5aj.2)

    /// The exact reported scenario: a newest-first-sorted episode list, user
    /// finishes the NEWEST episode. Auto-play must STOP — never fall back to
    /// an older, already-heard episode. Pre-fix, `nextEpisode(after:)` walked
    /// `sortedEpisodes` one slot forward from e3 (newest) and returned e2, an
    /// older episode the user had already listened to.
    func testRegressionFinishingNewestEpisodeInNewestFirstListStops() {
        let context = PodcastPlaybackContext(libraryItemId: "show-1", showTitle: "The Show", episodes: makeEpisodes(), order: .newestFirst)
        let next = context.nextEpisode(after: "e3", behavior: .nextUnplayed, isFinished: noneFinished)
        XCTAssertNil(next, "finishing the newest episode must stop, not auto-play an older already-heard episode")
    }

    /// `.continueInSortOrder` is explicitly opt-in to walking the display
    /// order backward in time under newest-first — that's the policy's whole
    /// point, unlike `.nextUnplayed`/the default. So under `.continueInSortOrder`
    /// finishing e3 (newest) legitimately advances to e2, confirming the two
    /// policies are genuinely distinct rather than `.continueInSortOrder`
    /// silently behaving like `.nextUnplayed`.
    func testContinueInSortOrderDeliberatelyAdvancesBackwardInTimeUnlikeNextUnplayed() {
        let context = PodcastPlaybackContext(libraryItemId: "show-1", showTitle: "The Show", episodes: makeEpisodes(), order: .newestFirst)
        let next = context.nextEpisode(after: "e3", behavior: .continueInSortOrder, isFinished: noneFinished)
        XCTAssertEqual(next?.id, "e2", "continueInSortOrder is the user opting into list-order traversal, including backward in time")
    }

    // MARK: - PodcastPlaybackContext.isFinished (drives skip-played hydration)

    private func progress(_ fraction: Double?, finished: Bool?) -> ABSMediaProgressDTO {
        let fractionJSON: String = fraction == nil ? "null" : "\(fraction!)"
        let finishedJSON: String = finished == nil ? "null" : "\(finished!)"
        let json = "{\"progress\": \(fractionJSON), \"isFinished\": \(finishedJSON)}"
        return try! JSONDecoder().decode(ABSMediaProgressDTO.self, from: Data(json.utf8))
    }

    func testIsFinishedNilProgressIsUnplayed() {
        XCTAssertFalse(PodcastPlaybackContext.isFinished(nil))
    }

    func testIsFinishedTrueWhenServerFlagIsSet() {
        XCTAssertTrue(PodcastPlaybackContext.isFinished(progress(0.4, finished: true)))
    }

    func testIsFinishedTrueWhenProgressFractionIsAtOrNearOne() {
        XCTAssertTrue(PodcastPlaybackContext.isFinished(progress(1.0, finished: false)))
        XCTAssertTrue(PodcastPlaybackContext.isFinished(progress(0.995, finished: false)))
    }

    func testIsFinishedFalseWhenPartiallyPlayed() {
        XCTAssertFalse(PodcastPlaybackContext.isFinished(progress(0.5, finished: false)))
    }
}
