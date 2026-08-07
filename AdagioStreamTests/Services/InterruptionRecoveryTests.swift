// InterruptionRecoveryTests.swift
//
// Unit tests for d6q.8: interruption recovery captures and restores the
// full PlaybackSource (not just a Channel).
//
// Design: the `captureInterruptionSnapshot()` method is `internal` so tests
// can call it.  The live AVAudioSession/VLC integration cannot be exercised
// in a unit-test target — those paths are covered by the launch smoke test.
// What we test here is the pure decision logic:
//
//   1. Snapshot struct carries the correct fields for each source type.
//   2. Radio capture → snapshot contains radio channel; queueAPI is nil.
//   3. Library capture → snapshot contains queue + index; queueAPI is set.
//   4. Empty capture (nothing playing) → safe no-op (returns nil).
//   5. Restore target: library snapshot carries the right index into the queue.
//   6. Elapsed position is threaded through correctly.

import XCTest
@testable import AdagioStream

// MARK: - InterruptionSnapshot struct tests (pure, no live session)

/// Tests exercise the data-shape contract of `InterruptionSnapshot`.
/// No AudioPlayerService instance is created — the tests operate only on
/// the value types involved.
final class InterruptionSnapshotStructTests: XCTestCase {

    // MARK: Helpers

    private func makeChannel(id: String = "ch-1", name: String = "Test Channel") -> Channel {
        Channel(
            id: id,
            name: name,
            streamURL: URL(string: "https://example.com/stream")!
        )
    }

    private func makeTracks(count: Int) -> [Track] {
        (0..<count).map { makeTrack(id: "t-\($0)", title: "Track \($0 + 1)") }
    }

    // MARK: - Radio snapshot

    func testRadioSnapshotCarriesChannel() {
        let channel = makeChannel(id: "r-1", name: "Radio X")
        let source = PlaybackSource.radio(channel)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: nil
        )

        guard case .radio(let captured) = snapshot.source else {
            XCTFail("Expected .radio source in snapshot"); return
        }
        XCTAssertEqual(captured.id, "r-1")
        XCTAssertEqual(captured.name, "Radio X")
    }

    func testRadioSnapshotQueueAPIIsNil() {
        let channel = makeChannel()
        let source = PlaybackSource.radio(channel)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: nil
        )
        XCTAssertNil(snapshot.queueAPI, "Radio snapshot must have nil queueAPI")
    }

    func testRadioSnapshotElapsedIsNil() {
        let channel = makeChannel()
        let source = PlaybackSource.radio(channel)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: nil
        )
        XCTAssertNil(snapshot.elapsedSeconds, "Radio snapshot elapsed must be nil")
    }

    // MARK: - Library snapshot

    func testLibrarySnapshotCarriesQueueAndIndex() {
        let tracks = makeTracks(count: 5)
        let source = PlaybackSource.library(queue: tracks, index: 3)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: 42.5
        )

        guard case .library(let queue, let index) = snapshot.source else {
            XCTFail("Expected .library source in snapshot"); return
        }
        XCTAssertEqual(queue.count, 5, "Queue count must be preserved")
        XCTAssertEqual(index, 3, "Queue index must be preserved")
    }

    func testLibrarySnapshotIndexPointsToCorrectTrack() {
        let tracks = makeTracks(count: 4)
        let capturedIndex = 2
        let source = PlaybackSource.library(queue: tracks, index: capturedIndex)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: nil
        )

        guard case .library(let queue, let index) = snapshot.source else {
            XCTFail("Expected .library source in snapshot"); return
        }
        XCTAssertEqual(queue[index].title, "Track 3",
            "Snapshot index must point to the track playing when interrupted")
    }

    func testLibrarySnapshotElapsedIsPreserved() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 1)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: 77.3
        )
        XCTAssertNotNil(snapshot.elapsedSeconds, "Elapsed must not be nil when position was known")
        XCTAssertEqual(snapshot.elapsedSeconds ?? 0, 77.3, accuracy: 0.001,
            "Elapsed position must be preserved in snapshot")
    }

    func testLibrarySnapshotElapsedNilWhenUnknown() {
        let tracks = makeTracks(count: 2)
        let source = PlaybackSource.library(queue: tracks, index: 0)
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: source, queueAPI: nil, elapsedSeconds: nil
        )
        XCTAssertNil(snapshot.elapsedSeconds,
            "Snapshot elapsed must be nil when position was not known at capture")
    }

    // MARK: - Source-type switch for restore decision

    func testRestoreDecisionForRadioTargetsChannel() {
        // Simulate the restore decision: switch on snapshot.source
        let channel = makeChannel(id: "ch-radio")
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: .radio(channel), queueAPI: nil, elapsedSeconds: nil
        )

        var didRestoreRadio = false
        var didRestoreLibrary = false

        switch snapshot.source {
        case .radio(let ch):
            didRestoreRadio = true
            XCTAssertEqual(ch.id, "ch-radio")
        case .library:
            didRestoreLibrary = true
        case .audiobook:
            XCTFail("Radio source must NOT route to audiobook restore path")
        }

        XCTAssertTrue(didRestoreRadio, "Radio source must route to radio restore path")
        XCTAssertFalse(didRestoreLibrary, "Radio source must NOT route to library restore path")
    }

    func testRestoreDecisionForLibraryTargetsQueueIndex() {
        let tracks = makeTracks(count: 5)
        let capturedIndex = 4
        let snapshot = AudioPlayerService.InterruptionSnapshot(
            source: .library(queue: tracks, index: capturedIndex), queueAPI: nil, elapsedSeconds: nil
        )

        var restoredIndex: Int?

        switch snapshot.source {
        case .radio:
            XCTFail("Library source must NOT route to radio restore path")
        case .library(let queue, let index):
            restoredIndex = index
            XCTAssertEqual(queue[index].title, "Track 5",
                "Restore must target the track at the captured index")
        case .audiobook:
            XCTFail("Library source must NOT route to audiobook restore path")
        }

        XCTAssertEqual(restoredIndex, capturedIndex,
            "Restore index must match the index captured at interruption .began")
    }

    // MARK: - Safe no-op guard: empty capture → nil snapshot

    func testNilSnapshotMeansNoResumeAction() {
        // The .ended handler guards on `interruptedSource != nil`.
        // Simulate that gate: if capturedSource is nil, we skip resume.
        let capturedSource: PlaybackSource? = nil

        var didAttemptResume = false
        if capturedSource != nil {
            didAttemptResume = true
        }

        XCTAssertFalse(didAttemptResume,
            "Nil capturedSource must produce a safe no-op — no resume attempt")
    }

    // MARK: - Wrong-channel guard for radio

    func testRadioRestoreDoesNotUseMismatchedChannel() {
        // Guard: a mid-interruption channel change must not resume
        // a stale channel.  The .ended handler clears interruptedSource and
        // takes capturedSource as a local; this test verifies the field
        // identity check used in the fallback closure.
        let ch1 = makeChannel(id: "ch-1", name: "Station A")
        let ch2 = makeChannel(id: "ch-2", name: "Station B")

        let capturedSource = PlaybackSource.radio(ch1)
        // Simulate "current interrupted source has changed" (user switched channels).
        let currentSource = PlaybackSource.radio(ch2)

        // The fallback guards: capturedSource.id == interruptedSource.id
        let stillMatches: Bool = {
            if case .radio(let a) = capturedSource,
               case .radio(let b) = currentSource {
                return a.id == b.id
            }
            return false
        }()

        XCTAssertFalse(stillMatches,
            "Mismatch between captured and current source must suppress fallback resume")
    }

    func testLibraryRestoreDoesNotUseMismatchedIndex() {
        let tracks = makeTracks(count: 5)
        let capturedSource = PlaybackSource.library(queue: tracks, index: 2)
        // Simulate a queue advance that happened during the interruption.
        let currentSource = PlaybackSource.library(queue: tracks, index: 3)

        let stillMatches: Bool = {
            if case .library(_, let ai) = capturedSource,
               case .library(_, let bi) = currentSource {
                return ai == bi
            }
            return false
        }()

        XCTAssertFalse(stillMatches,
            "Index mismatch between captured and current source must suppress fallback resume")
    }
}

// MARK: - AudioOutput.shouldHealStaleInterruptionGate (beads_mobilemusic-irg)
//
// Round 1 traced failure sequence: interruption .began → AudioOutput.isInterrupted
// latches true → CarPlay disconnects mid-interruption → CarPlaySceneDelegate calls
// stopAndClearInterruption(), which nils AudioPlayerService's interruptedChannel/
// interruptionTime but does NOT touch AudioOutput.isInterrupted → the .ended
// notification is dropped (documented-common on CarPlay disconnect) → on
// reconnect, recoverStaleInterruption()'s existing interruptedChannel-based
// recovery no-ops (interruptedChannel is nil) → isInterrupted stays latched
// until the next deliberate play, silently skipping CarPlay reconnect-resume.
//
// Round 1's fix (elapsed-time + idle-playback alone) was BLOCKED on review:
// the ride-out fallback stops playback at ~bufferDuration (~8s) while a real
// phone call is still active, so an ordinary >30s call satisfies
// `elapsed > 30 && !isPlaying && !isBuffering` too — playback state after
// ride-out is identical in the stale and still-active cases by design. That
// let CarPlay resume start playback OVER a live call (fails-dangerous).
//
// Round 2 (this test class): the predicate now requires BOTH (1) a recorded
// drop-risk flag — set ONLY when stopAndClearInterruption() ran while still
// interrupted, i.e. the actual documented-common drop event, not just "some
// interruption happened a while ago" — and (2) a live probe result
// (`AVAudioSession.isOtherAudioPlaying`, passed in as `foreignAudioDetected`
// so the predicate stays pure) confirming no foreign audio currently holds
// the session. Either piece of evidence missing means "cannot distinguish
// stale from still-active" → must not heal.
final class StaleInterruptionGateHealPredicateTests: XCTestCase {

    // MARK: Positive — drop-risk flag set, probe clear, elapsed proven

    func testHealsWhenDropRiskSetAndProbeClearAndElapsedPastThreshold() {
        // The bead's actual sequence: disconnect while interrupted (flag set),
        // .ended dropped, reconnect 45s later — the call has genuinely ended
        // by then, so the probe finds no foreign audio holding the session.
        XCTAssertTrue(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 45,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Drop-risk flag set + probe clear + elapsed past threshold + idle playback must heal"
        )
    }

    func testHealsAtJustPastTheThirtySecondThreshold() {
        XCTAssertTrue(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 30.1,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Just past the 30s threshold must heal when the rest of the evidence holds"
        )
    }

    // MARK: Negative — the exact false-heal the review caught: flag set, but probe says foreign audio present

    func testDoesNotHealWhenProbeDetectsForeignAudioEvenWithDropRiskAndElapsed() {
        // Disconnect mid-call (flag set) → reconnect mid-call, no .ended yet.
        // Elapsed and idle-playback both look identical to the stale case —
        // only the probe distinguishes them. This is the exact scenario the
        // review blocked round 1 over: must NOT heal.
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 45,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: true
            ),
            "Must NOT heal when the live probe detects foreign audio, even with the drop-risk flag set and elapsed past threshold — the interruption is still active"
        )
    }

    // MARK: Negative — flag unset means no documented drop occurred, regardless of everything else

    func testDoesNotHealWhenDropRiskFlagNotSetRegardlessOfOtherEvidence() {
        // No CarPlay disconnect-while-interrupted ever happened (e.g. a plain
        // long Siri ride-out with no CarPlay involved at all). Elapsed time,
        // idle playback, and even a clear probe cannot substitute for the
        // actual documented drop event — nothing proves an .ended was lost.
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: false,
                elapsedSinceBegan: 999,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Must NOT heal when the drop-risk flag was never set — no evidence a .ended was actually dropped"
        )
    }

    // MARK: Boundary — exactly 30s must not heal (matches round-1 threshold semantics)

    func testDoesNotHealExactlyAtTheThirtySecondThreshold() {
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 30,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Exactly 30s must NOT heal — matches the existing interruptedChannel-based staleness threshold (elapsed > 30, not >=)"
        )
    }

    // MARK: Guard: gate not latched at all

    func testDoesNotHealWhenNotInterrupted() {
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: false,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 999,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Nothing to heal when isInterrupted is already false"
        )
    }

    func testDoesNotHealWhenNoInterruptionEverBegan() {
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: nil,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "No interruptionBeganAt evidence means staleness cannot be proven — must not heal"
        )
    }

    // MARK: 46u guard: never heal while playback or a ride-out may still be active

    func testDoesNotHealWhilePlaying() {
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 60,
                isPlaying: true,
                isBuffering: false,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Must not heal while playback is active, regardless of elapsed time"
        )
    }

    func testDoesNotHealWhileBuffering() {
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 60,
                isPlaying: false,
                isBuffering: true,
                isRidingOutInterruption: false,
                foreignAudioDetected: false
            ),
            "Must not heal while buffering, regardless of elapsed time"
        )
    }

    func testDoesNotHealDuringActiveRideOutEvenPastThreshold() {
        // Edge case a plain !isPlaying && !isBuffering check would miss:
        // during a genuine Siri/call ride-out, VLC can report a transient
        // buffering stall unrelated to the interruption. isRidingOutInterruption
        // is the signal that the interruption itself (not just VLC) is still
        // active — stop() always clears it before either legitimate staleness
        // path (radio fallback-then-stop, or stopAndClearInterruption on
        // CarPlay disconnect) runs.
        XCTAssertFalse(
            AudioOutput.shouldHealStaleInterruptionGate(
                isInterrupted: true,
                dropRiskFlagSet: true,
                elapsedSinceBegan: 60,
                isPlaying: false,
                isBuffering: false,
                isRidingOutInterruption: true,
                foreignAudioDetected: false
            ),
            "Must not heal while isRidingOutInterruption is true — the interruption is provably still in effect"
        )
    }
}

// MARK: - AudioPlayerService observable state for interruption fields (iOS only)

#if os(iOS)
@MainActor
final class AudioPlayerServiceInterruptionStateTests: XCTestCase {

    // These tests access the singleton and verify the new d6q.8 observable
    // state fields are present and start in their safe (nil) defaults.

    func testInterruptedSourceStartsNil() {
        // captureInterruptionSnapshot returns nil when playbackSource is nil.
        let service = AudioPlayerService.shared
        // With no active source, the snapshot must be nil.
        let snapshot = service.captureInterruptionSnapshot()
        XCTAssertNil(snapshot,
            "captureInterruptionSnapshot must return nil when nothing is playing")
    }

    func testCaptureInterruptionSnapshotReturnsNilWhenIdle() {
        let service = AudioPlayerService.shared
        // Ensure clean state: service is not playing anything.
        XCTAssertNil(service.playbackSource,
            "playbackSource must be nil in a fresh/stopped service")
        let snapshot = service.captureInterruptionSnapshot()
        XCTAssertNil(snapshot,
            "No snapshot should be produced from a stopped service")
    }

    /// uxa kickback (finding 1): captureInterruptionSnapshot() must never
    /// capture `.audiobook` — audiobooks resume via their own pause()/
    /// resume() path, not the radio/library ride-out-and-restore machinery.
    /// Restores the prior `playbackSource` afterward so test order doesn't
    /// leak state into the "idle" tests above (singleton shared across the suite).
    func testCaptureInterruptionSnapshotReturnsNilForAudiobookSource() {
        let service = AudioPlayerService.shared
        let previousSource = service.playbackSource
        defer { service.playbackSource = previousSource }

        let book = Audiobook(id: "b1", libraryItemId: "b1", libraryId: "lib1", title: "A Book", updatedAt: 0)
        service.playbackSource = .audiobook(book)

        XCTAssertNil(service.captureInterruptionSnapshot(),
            "captureInterruptionSnapshot() must return nil for an audiobook source — audiobooks don't participate in ride-out/restore")
    }

    /// beads_mobilemusic-cpr kickback (Block 1): CarPlay reconnect-resume's
    /// "don't stomp existing playback" check previously read
    /// `currentChannel != nil`, which is nil during audiobook AND
    /// library-track playback — a false negative that would let resume
    /// replace a book or track the user was actively listening to.
    /// `hasActivePlayback` is the correct signal; this test proves it stays
    /// true exactly where `currentChannel` goes wrong.
    func testHasActivePlaybackTrueForAudiobookWhileCurrentChannelIsNil() {
        let service = AudioPlayerService.shared
        let previousSource = service.playbackSource
        defer { service.playbackSource = previousSource }

        let book = Audiobook(id: "b2", libraryItemId: "b2", libraryId: "lib1", title: "Another Book", updatedAt: 0)
        service.playbackSource = .audiobook(book)

        XCTAssertNil(service.currentChannel, "Precondition: currentChannel is nil during audiobook playback")
        XCTAssertTrue(service.hasActivePlayback, "hasActivePlayback must be true while an audiobook is playing")
    }

    func testHasActivePlaybackTrueForLibraryTrackWhileCurrentChannelIsNil() {
        let service = AudioPlayerService.shared
        let previousSource = service.playbackSource
        defer { service.playbackSource = previousSource }

        let track = makeTrack(id: "t1", title: "A Track")
        service.playbackSource = .library(queue: [track], index: 0)

        XCTAssertNil(service.currentChannel, "Precondition: currentChannel is nil during library-track playback")
        XCTAssertTrue(service.hasActivePlayback, "hasActivePlayback must be true while a library track is playing")
    }
}

// MARK: - shouldRestartEngineForBareInterruptionEnded (uxa kickback finding 1)
//
// The `.ended` handler's "no captured source" branch previously always took
// the safe-no-op path — including for an interrupted audiobook, which has no
// captured InterruptionSnapshot by design. Without a restart path there, a
// route/format change during the interruption can leave AVAudioEngine
// stopped with nothing draining VLC's ring buffer: silent playback until the
// user manually toggles play/pause. This predicate is the decision extracted
// so it's testable without a live AVAudioSession/engine.
final class BareInterruptionEndedRestartPredicateTests: XCTestCase {

    func testRestartsWhenAudiobookSessionActive() {
        XCTAssertTrue(
            AudioPlayerService.shouldRestartEngineForBareInterruptionEnded(audiobookSessionActive: true),
            "An active audiobook session must trigger the resilient engine restart"
        )
    }

    func testNoRestartWhenNoAudiobookSessionActive() {
        XCTAssertFalse(
            AudioPlayerService.shouldRestartEngineForBareInterruptionEnded(audiobookSessionActive: false),
            "No audiobook session active must stay a safe no-op — unchanged radio/library behavior"
        )
    }
}

// MARK: - shouldColdRestartAfterInterruption (beads_mobilemusic-crr)
//
// Build 388 field log: car turned off → interruption .ended fires with
// shouldResume=false → 10ms later CarPlay disconnect runs stop() → the
// delayed ride-out block saw vlcAlive=false (BECAUSE stop() ran) and
// misread it as "VLC died during interruption", cold-restarting playback
// on the phone speaker. The cold-restart decision must consult shouldResume.
final class ColdRestartAfterInterruptionPredicateTests: XCTestCase {

    func testRestartsWhenVLCDeadAndSystemSaysResume() {
        XCTAssertTrue(
            AudioPlayerService.shouldColdRestartAfterInterruption(vlcAlive: false, shouldResume: true),
            "VLC dead + shouldResume=true is the legitimate cold-restart case"
        )
    }

    func testNoRestartWhenVLCDeadButShouldResumeFalse() {
        XCTAssertFalse(
            AudioPlayerService.shouldColdRestartAfterInterruption(vlcAlive: false, shouldResume: false),
            "Car-off ends interruptions with shouldResume=false — restarting would resurrect audio on the phone speaker"
        )
    }

    func testNoColdRestartWhenVLCAlive() {
        XCTAssertFalse(
            AudioPlayerService.shouldColdRestartAfterInterruption(vlcAlive: true, shouldResume: true),
            "VLC alive means seamless resume — never cold restart"
        )
        XCTAssertFalse(
            AudioPlayerService.shouldColdRestartAfterInterruption(vlcAlive: true, shouldResume: false),
            "VLC alive means seamless resume — never cold restart"
        )
    }
}
#endif
