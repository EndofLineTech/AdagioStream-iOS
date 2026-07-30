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

    // MARK: - beads_mobilemusic-t96.26: guard ownership through play()'s debounce

    func testUserInitiatedPlayNeverOwnsGuardEvenWhileOneIsHeld() {
        // A manual tap must never be blocked, delayed, or treated as owning
        // a reconnect's claim — regardless of whether some other reconnect
        // attempt happens to be in flight at the same moment.
        XCTAssertFalse(
            AudioPlayerService.playCallOwnsReconnectGuard(userInitiated: true, reconnectInFlightSince: Date()),
            "User-initiated play must never own the reconnect guard"
        )
        XCTAssertFalse(
            AudioPlayerService.playCallOwnsReconnectGuard(userInitiated: true, reconnectInFlightSince: nil),
            "User-initiated play must never own the reconnect guard"
        )
    }

    func testAutomaticPlayOwnsGuardOnlyWhenOneIsActuallyHeld() {
        // An automatic play (path-monitor / deferred-reconnect) owns the
        // guard only if its caller already claimed it before calling in.
        // If nothing is held, this is some other automatic path (e.g. a
        // cold-restart after a survived short interruption) that never
        // claimed a guard in the first place — it must not adopt one.
        XCTAssertTrue(
            AudioPlayerService.playCallOwnsReconnectGuard(userInitiated: false, reconnectInFlightSince: Date()),
            "Automatic play must carry an already-held guard through its debounce"
        )
        XCTAssertFalse(
            AudioPlayerService.playCallOwnsReconnectGuard(userInitiated: false, reconnectInFlightSince: nil),
            "Automatic play must not claim guard ownership that was never held"
        )
    }

}

// MARK: - Claim/release bookkeeping on the live singleton (iOS only)
//
// claimReconnectGuard()/releaseReconnectGuard() only mutate
// `reconnectInFlightSince` (plus a log call) — no VLC/AVAudioSession side
// effects — so they're safe to exercise directly on the shared singleton.
// The debounce-carrying behavior itself (inside play(), which does touch
// VLC/AVAudioSession/DispatchWorkItem timing) is not exercisable here; that
// path is covered by the pure decision function above plus manual/field
// verification.

// MARK: - shouldSuppressPathReconnect (beads_mobilemusic-crr)
//
// Build 388 field log: while riding out a car-off interruption (no .ended
// yet), the path monitor saw the cellular→wifi transition as the user walked
// inside and called play(), restarting audio on the phone speaker. While an
// interruption is in progress, its handler owns the resume decision.
final class PathReconnectSuppressionPredicateTests: XCTestCase {

    func testSuppressedWhileRidingOutInterruption() {
        XCTAssertTrue(
            AudioPlayerService.shouldSuppressPathReconnect(ridingOut: true, interruptedSourceActive: true),
            "Short ride-out window must suppress path-driven reconnect"
        )
    }

    func testSuppressedWhileInterruptedSourceCapturedAwaitingEnded() {
        // Long path: the fallback already stopped VLC (ridingOut cleared) but
        // interruptedSource is still captured awaiting .ended.
        XCTAssertTrue(
            AudioPlayerService.shouldSuppressPathReconnect(ridingOut: false, interruptedSourceActive: true),
            "Captured interrupted source awaiting .ended must suppress path-driven reconnect"
        )
    }

    func testSuppressedWhileRidingOutEvenWithoutCapturedSource() {
        // beads_mobilemusic-crr review: complete the truth table — the ride-out
        // flag alone must suppress, even if the captured source is (unexpectedly)
        // already cleared.
        XCTAssertTrue(
            AudioPlayerService.shouldSuppressPathReconnect(ridingOut: true, interruptedSourceActive: false),
            "Ride-out in progress must suppress path-driven reconnect regardless of captured source"
        )
    }

    func testNotSuppressedWhenNoInterruptionInProgress() {
        // The reconnect feature's legitimate case: dead stream, network back,
        // no interruption anywhere in flight.
        XCTAssertFalse(
            AudioPlayerService.shouldSuppressPathReconnect(ridingOut: false, interruptedSourceActive: false),
            "No interruption in progress — path-driven reconnect must proceed"
        )
    }
}

#if os(iOS)
@MainActor
final class ReconnectGuardSingletonTests: XCTestCase {

    func testClaimReleaseRoundTripOnSingleton() {
        let service = AudioPlayerService.shared
        service.releaseReconnectGuard() // ensure clean slate regardless of test order
        XCTAssertTrue(service.claimReconnectGuard(path: "test-claim"), "Guard must be claimable when free")
        XCTAssertFalse(service.claimReconnectGuard(path: "test-second-claim"), "A second claim must be rejected while the first is held")
        service.releaseReconnectGuard()
        XCTAssertTrue(service.claimReconnectGuard(path: "test-reclaim-after-release"), "Guard must be reclaimable after release")
        service.releaseReconnectGuard() // leave clean for other tests
    }
}
#endif
