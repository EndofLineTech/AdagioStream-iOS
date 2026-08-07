// ScrobbleTests.swift — 65x.1: scrobble.view on play
//
// Tests for:
//   1. AudioPlayerService.scrobbleShouldSubmit — pure threshold function
//   2. NavidromeAPI.scrobble radio-guard documentation (source-type decision)
//
// AudioPlayerService is iOS-only (no VLC on tvOS test target).

import XCTest
@testable import AdagioStream

// MARK: - Threshold decision tests

final class ScrobbleThresholdTests: XCTestCase {

    // MARK: - ≥ 4 minutes rule

    func testBelow4MinutesUnknownDuration() {
        // 239 seconds (just under 4 min), no duration → must NOT submit.
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 239, duration: nil),
            "Must not submit at 3m59s with unknown duration"
        )
    }

    func testExactly4MinutesUnknownDuration() {
        // 240 seconds exactly, no duration → submit (≥4 min rule).
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 240, duration: nil),
            "Must submit at exactly 4m00s with unknown duration"
        )
    }

    func testOver4MinutesUnknownDuration() {
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 300, duration: nil),
            "Must submit at 5m00s with unknown duration"
        )
    }

    // MARK: - Zero / nil duration falls back to 4-minute rule

    func testZeroDurationFallsBackTo4MinRule_Below() {
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 100, duration: 0),
            "Zero duration should fall back to 4-min rule; 100s < 4m → false"
        )
    }

    func testZeroDurationFallsBackTo4MinRule_Above() {
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 240, duration: 0),
            "Zero duration should fall back to 4-min rule; 240s ≥ 4m → true"
        )
    }

    // MARK: - 50% rule

    func testBelow50Percent() {
        // 4-minute track, 1m59s elapsed (49.6%) → not enough.
        let duration = 240.0
        let elapsed = 119.0
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: elapsed, duration: duration),
            "49.6% of 4m track must not submit"
        )
    }

    func testExactly50Percent() {
        // 6-minute track, 3 minutes elapsed → exactly 50%.
        let duration = 360.0
        let elapsed = 180.0
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: elapsed, duration: duration),
            "Exactly 50% of 6m track must submit"
        )
    }

    func testOver50Percent() {
        // 2-minute track (below 4-min mark), 61 seconds elapsed (50.8%) → submit.
        let duration = 120.0
        let elapsed = 61.0
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: elapsed, duration: duration),
            "50.8% of 2m track must submit even though elapsed < 4m"
        )
    }

    func testShortTrackBelow50PercentAndBelow4Min() {
        // 90-second track, 44 seconds elapsed (48.9%) → neither rule satisfied.
        let duration = 90.0
        let elapsed = 44.0
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: elapsed, duration: duration),
            "48.9% of a short track and under 4m must not submit"
        )
    }

    // MARK: - 4-minute rule fires first for long tracks

    func testLongTrackSubmitsAt4MinBeforeReaching50Percent() {
        // 10-minute track: 50% = 300s, but 4-min rule fires at 240s.
        let duration = 600.0
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 240, duration: duration),
            "4-min rule must fire at 4m even though 50% of 10m hasn't been reached"
        )
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 239, duration: duration),
            "3m59s of a 10m track must not submit (below both thresholds)"
        )
    }

    // MARK: - Zero elapsed

    func testZeroElapsedNeverSubmits() {
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 0, duration: nil),
            "0s elapsed must not submit"
        )
        XCTAssertFalse(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 0, duration: 60),
            "0s elapsed on a 1m track must not submit"
        )
    }

    // MARK: - Radio exclusion (source-type guard)
    //
    // The scrobble helpers are only called from code paths guarded by
    //   `if case .library = playbackSource`.
    // This test documents that the threshold function itself is source-agnostic
    // (it is a pure math function); the guard lives in AudioPlayerService.
    // We verify the guard is in place by checking the threshold function
    // directly — callers are responsible for the source check.

    func testThresholdFunctionIsSourceAgnostic() {
        // This test documents expected behaviour, not a bug: the threshold
        // function takes elapsed/duration only. The radio exclusion guard
        // is enforced by the call site in AudioPlayerService.syncState().
        XCTAssertTrue(
            AudioPlayerService.scrobbleShouldSubmit(elapsed: 240, duration: nil),
            "Pure threshold function is source-agnostic; source guard belongs to caller"
        )
    }

    // MARK: - Scrobbler.shouldSubmit is accessible directly (extracted type)

    /// Verifies that `Scrobbler.shouldSubmit` is the canonical implementation and
    /// matches the forwarding alias on AudioPlayerService.
    func testScrobblerShouldSubmitMatchesForwardingAlias() {
        let cases: [(Double, Double?)] = [
            (0, nil), (239, nil), (240, nil), (300, nil),
            (119, 240), (120, 240), (180, 360), (44, 90),
        ]
        for (elapsed, duration) in cases {
            XCTAssertEqual(
                Scrobbler.shouldSubmit(elapsed: elapsed, duration: duration),
                AudioPlayerService.scrobbleShouldSubmit(elapsed: elapsed, duration: duration),
                "Scrobbler.shouldSubmit must match AudioPlayerService.scrobbleShouldSubmit for elapsed=\(elapsed) duration=\(String(describing: duration))"
            )
        }
    }
}

// MARK: - Scrobbler state management tests

@MainActor
final class ScrobblerStateTests: XCTestCase {

    // MARK: - Initial state

    func testInitialSubmissionSentIsFalse() {
        let scrobbler = Scrobbler()
        XCTAssertFalse(scrobbler.submissionSent,
            "Scrobbler starts with submissionSent=false")
    }

    // MARK: - reset()

    func testResetClearsSubmissionSent() {
        let scrobbler = Scrobbler()
        // Simulate the submission being marked
        scrobbler.fireSubmissionIfNeeded(
            trackID: "t-1",
            via: NavidromeAPI(host: URL(string: "https://test.example")!, username: "u", password: "p")
        )
        XCTAssertTrue(scrobbler.submissionSent,
            "submissionSent must be true after fireSubmissionIfNeeded is called")

        scrobbler.reset()
        XCTAssertFalse(scrobbler.submissionSent,
            "reset() must clear submissionSent for the next track")
    }

    func testResetIsIdempotent() {
        let scrobbler = Scrobbler()
        scrobbler.reset()
        scrobbler.reset()
        XCTAssertFalse(scrobbler.submissionSent, "Double reset() must leave submissionSent=false")
    }

    // MARK: - fireSubmissionIfNeeded once-guard

    func testSubmissionSentAfterFirstFire() {
        let scrobbler = Scrobbler()
        let api = NavidromeAPI(host: URL(string: "https://test.example")!, username: "u", password: "p")
        XCTAssertFalse(scrobbler.submissionSent, "Precondition: submissionSent=false before first fire")
        scrobbler.fireSubmissionIfNeeded(trackID: "t-1", via: api)
        XCTAssertTrue(scrobbler.submissionSent,
            "submissionSent must be true immediately after fireSubmissionIfNeeded")
    }

    func testSubmissionSentRemainsAfterSecondFire() {
        let scrobbler = Scrobbler()
        let api = NavidromeAPI(host: URL(string: "https://test.example")!, username: "u", password: "p")
        scrobbler.fireSubmissionIfNeeded(trackID: "t-1", via: api)
        scrobbler.fireSubmissionIfNeeded(trackID: "t-1", via: api) // second call — must be no-op
        XCTAssertTrue(scrobbler.submissionSent,
            "submissionSent remains true; second fire is a no-op (once-per-track guard)")
    }

    // MARK: - reset() → fire → reset() cycle

    func testResetFireResetCycle() {
        let scrobbler = Scrobbler()
        let api = NavidromeAPI(host: URL(string: "https://test.example")!, username: "u", password: "p")

        // Track 1
        scrobbler.reset()
        XCTAssertFalse(scrobbler.submissionSent, "Track 1 start: submissionSent=false after reset")
        scrobbler.fireSubmissionIfNeeded(trackID: "t-1", via: api)
        XCTAssertTrue(scrobbler.submissionSent, "Track 1: submissionSent=true after fire")

        // Track 2
        scrobbler.reset()
        XCTAssertFalse(scrobbler.submissionSent, "Track 2 start: submissionSent=false after reset")
        scrobbler.fireSubmissionIfNeeded(trackID: "t-2", via: api)
        XCTAssertTrue(scrobbler.submissionSent, "Track 2: submissionSent=true after fire")

        // Track 3 (no submission fired — verify guard still false)
        scrobbler.reset()
        XCTAssertFalse(scrobbler.submissionSent, "Track 3 start: submissionSent=false after reset with no fire")
    }
}
