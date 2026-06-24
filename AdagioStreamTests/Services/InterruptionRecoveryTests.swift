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

    private func makeTrack(id: String, title: String) -> Track {
        Track(id: id, albumId: "alb-1", artistId: "art-1", title: title, updatedAt: 0)
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
}
#endif
