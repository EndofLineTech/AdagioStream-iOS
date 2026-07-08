// ReconnectGuardTests.swift
//
// Unit tests for beads_mobilemusic-t96.4: AudioPlayerService.canClaimReconnectGuard
// is a static pure function deciding whether one of the four independent
// reconnect/retry paths (path-monitor force-play, deferred reconnect,
// probe-and-retry, watchdog restart) may claim the shared in-flight guard.
//
// Pure decision logic — no live AudioPlayerService/VLC required.

import XCTest
@testable import AdagioStream

final class ReconnectGuardTests: XCTestCase {

    private let staleAfter: TimeInterval = 120

    func testClaimAllowedWhenNoAttemptInFlight() {
        XCTAssertTrue(
            AudioPlayerService.canClaimReconnectGuard(claimedAt: nil, now: Date(), staleAfter: staleAfter),
            "Guard must be claimable when nothing currently holds it"
        )
    }

    func testClaimRejectedWhileAnotherAttemptIsFresh() {
        let now = Date()
        let claimedAt = now.addingTimeInterval(-5) // held 5s ago
        XCTAssertFalse(
            AudioPlayerService.canClaimReconnectGuard(claimedAt: claimedAt, now: now, staleAfter: staleAfter),
            "A second path must not claim the guard while another attempt is in flight"
        )
    }

    func testClaimRejectedRightUpToStaleness() {
        let now = Date()
        let claimedAt = now.addingTimeInterval(-staleAfter) // exactly at the threshold
        XCTAssertFalse(
            AudioPlayerService.canClaimReconnectGuard(claimedAt: claimedAt, now: now, staleAfter: staleAfter),
            "A guard exactly at the staleness threshold has not yet expired"
        )
    }

    func testClaimAllowedOnceGuardIsStale() {
        // A guard held by a path that crashed or forgot to release must not
        // wedge recovery forever — the staleness escape kicks in past the
        // longest retry window.
        let now = Date()
        let claimedAt = now.addingTimeInterval(-(staleAfter + 1))
        XCTAssertTrue(
            AudioPlayerService.canClaimReconnectGuard(claimedAt: claimedAt, now: now, staleAfter: staleAfter),
            "A guard older than staleAfter must be treated as abandoned and reclaimable"
        )
    }
}
