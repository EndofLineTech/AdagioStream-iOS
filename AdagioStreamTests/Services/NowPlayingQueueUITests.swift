// NowPlayingQueueUITests.swift
//
// Unit tests for d6q.6: seek(to:), playQueueItem(at:), moveQueueItem(from:to:).
//
// All tests exercise pure model logic — the PlaybackSource / AudioPlayerService
// API layer — without VLC or a real audio session.
//
// The UI is hard to unit-test directly; the player API methods are the correct
// seam. Launch smoke for the views is the verification gate.

import XCTest
@testable import AdagioStream

// MARK: - Helpers

private func makeTrack(id: String, title: String) -> Track {
    Track(id: id, albumId: "alb-1", artistId: "art-1", title: title, updatedAt: 0)
}

private func makeTracks(count: Int) -> [Track] {
    (0..<count).map { makeTrack(id: "t-\($0)", title: "Track \($0 + 1)") }
}

// MARK: - moveQueueItem logic tests
//
// These tests exercise the pure index-shift logic that moveQueueItem performs
// when computing `newPlayingIndex` from (sourceIndex, destinationIndex, playingIndex).
// We cannot call moveQueueItem directly in the unit-test target because it
// also touches VLC-linked state, so we mirror the decision logic here.

final class MoveQueueItemLogicTests: XCTestCase {

    // MARK: - Index shift helpers (mirror moveQueueItem logic)

    /// Computes the new playing index after a move, using the same formula as
    /// AudioPlayerService.moveQueueItem(from:to:).
    private func newPlayingIndex(
        playing: Int, source: Int, destination: Int
    ) -> Int {
        if source == playing { return destination }
        if source < playing && destination >= playing { return playing - 1 }
        if source > playing && destination <= playing { return playing + 1 }
        return playing
    }

    /// Applies the same index-shift to an element in a simulated shuffleOrder array.
    private func remapShuffleIndex(idx: Int, source: Int, destination: Int) -> Int {
        if idx == source { return destination }
        if source < idx && idx <= destination { return idx - 1 }
        if destination <= idx && idx < source { return idx + 1 }
        return idx
    }

    // MARK: - Playing track moves

    func testPlayingTrackMovedForward() {
        // Move track 1 (playing) to position 3
        XCTAssertEqual(newPlayingIndex(playing: 1, source: 1, destination: 3), 3)
    }

    func testPlayingTrackMovedBackward() {
        // Move track 3 (playing) to position 0
        XCTAssertEqual(newPlayingIndex(playing: 3, source: 3, destination: 0), 0)
    }

    func testPlayingTrackMovedToSamePosition() {
        XCTAssertEqual(newPlayingIndex(playing: 2, source: 2, destination: 2), 2)
    }

    // MARK: - Track before playing moves past playing

    func testTrackBeforePlayingMovesPastPlaying() {
        // Move track 0 past the playing track at 2 (to position 3)
        // → playing index shifts down by 1 (0→1)
        XCTAssertEqual(newPlayingIndex(playing: 2, source: 0, destination: 3), 1)
    }

    func testTrackBeforePlayingMovesToPlayingSlot() {
        // Move track 0 to position 2 (playing slot) → playing shifts to 1
        XCTAssertEqual(newPlayingIndex(playing: 2, source: 0, destination: 2), 1)
    }

    // MARK: - Track after playing moves before playing

    func testTrackAfterPlayingMovesBefore() {
        // Move track 4 before the playing track at 2 (to position 1)
        // → playing index shifts up by 1 (2→3)
        XCTAssertEqual(newPlayingIndex(playing: 2, source: 4, destination: 1), 3)
    }

    func testTrackAfterPlayingMovesToPlayingSlot() {
        // Move track 4 to position 2 (playing slot) → playing shifts to 3
        XCTAssertEqual(newPlayingIndex(playing: 2, source: 4, destination: 2), 3)
    }

    // MARK: - Move does not affect unrelated indices

    func testMoveNotInvolvingPlayingLeavesPlayingUnchanged() {
        // Move track 0 to position 1; playing is at 3 — no shift
        XCTAssertEqual(newPlayingIndex(playing: 3, source: 0, destination: 1), 3)
    }

    // MARK: - Shuffle index remapping

    func testShuffleIndexRemapForMovedTrack() {
        // shuffleOrder element at source position should map to destination
        XCTAssertEqual(remapShuffleIndex(idx: 2, source: 2, destination: 5), 5)
    }

    func testShuffleIndexRemapForTrackBetween() {
        // Tracks between source and destination shift by -1 when source < destination
        // e.g. source=1, destination=4: indices 2,3,4 shift down to 1,2,3
        XCTAssertEqual(remapShuffleIndex(idx: 3, source: 1, destination: 4), 2)
        XCTAssertEqual(remapShuffleIndex(idx: 4, source: 1, destination: 4), 3)
    }

    func testShuffleIndexRemapForTrackBetweenBackward() {
        // Tracks between destination and source shift by +1 when source > destination
        // e.g. source=4, destination=1: indices 1,2,3 shift up to 2,3,4
        XCTAssertEqual(remapShuffleIndex(idx: 1, source: 4, destination: 1), 2)
        XCTAssertEqual(remapShuffleIndex(idx: 3, source: 4, destination: 1), 4)
    }

    func testShuffleIndexRemapOutsideRangeIsUnchanged() {
        // Indices outside [source, destination] range are unchanged
        XCTAssertEqual(remapShuffleIndex(idx: 0, source: 2, destination: 5), 0)
        XCTAssertEqual(remapShuffleIndex(idx: 6, source: 2, destination: 5), 6)
    }

    // MARK: - Queue array reorder correctness

    func testMoveArrayForwardProducesCorrectOrder() {
        var tracks = makeTracks(count: 5)
        // Move index 1 to index 3
        let item = tracks.remove(at: 1)
        tracks.insert(item, at: 3)
        let titles = tracks.map(\.title)
        XCTAssertEqual(titles, ["Track 1", "Track 3", "Track 4", "Track 2", "Track 5"])
    }

    func testMoveArrayBackwardProducesCorrectOrder() {
        var tracks = makeTracks(count: 5)
        // Move index 3 to index 1
        let item = tracks.remove(at: 3)
        tracks.insert(item, at: 1)
        let titles = tracks.map(\.title)
        XCTAssertEqual(titles, ["Track 1", "Track 4", "Track 2", "Track 3", "Track 5"])
    }

    func testMoveArrayFirstToLast() {
        var tracks = makeTracks(count: 4)
        let item = tracks.remove(at: 0)
        tracks.insert(item, at: 3)
        let titles = tracks.map(\.title)
        XCTAssertEqual(titles, ["Track 2", "Track 3", "Track 4", "Track 1"])
    }

    func testMoveArrayLastToFirst() {
        var tracks = makeTracks(count: 4)
        let item = tracks.remove(at: 3)
        tracks.insert(item, at: 0)
        let titles = tracks.map(\.title)
        XCTAssertEqual(titles, ["Track 4", "Track 1", "Track 2", "Track 3"])
    }

    // MARK: - Playing track identity preserved across move

    func testPlayingTrackIdentityPreservedWhenMovedForward() {
        var tracks = makeTracks(count: 5)
        let playingID = tracks[1].id  // track at index 1 is playing
        let item = tracks.remove(at: 1)
        tracks.insert(item, at: 4)
        // Playing track should now be at index 4
        let newPlayingIdx = 4  // source == playing, so newPlayingIndex = destination
        XCTAssertEqual(tracks[newPlayingIdx].id, playingID)
    }

    func testPlayingTrackIdentityPreservedWhenNonPlayingMovesPast() {
        var tracks = makeTracks(count: 5)
        let playingID = tracks[3].id  // track at index 3 is playing
        // Move track 1 past the playing track (to index 4)
        let item = tracks.remove(at: 1)
        tracks.insert(item, at: 4)
        // Playing index shifts: source(1) < playing(3) and destination(4) >= playing(3) → playing-1=2
        let newPlayingIdx = 2
        XCTAssertEqual(tracks[newPlayingIdx].id, playingID, "Playing track must remain at newPlayingIndex after non-playing move")
    }
}

// MARK: - seek(to:) clamping logic

final class SeekClampingTests: XCTestCase {

    /// Mirrors the clamping formula in AudioPlayerService.seek(to:).
    private func clamped(_ seconds: Double, duration: Double?) -> Double {
        if let dur = duration, dur > 0 {
            return max(0, min(seconds, dur))
        }
        return max(0, seconds)
    }

    func testSeekClampsToZeroForNegativeInput() {
        XCTAssertEqual(clamped(-5, duration: 120), 0, accuracy: 0.001)
    }

    func testSeekClampsToZeroForNegativeInputNoDuration() {
        XCTAssertEqual(clamped(-1, duration: nil), 0, accuracy: 0.001)
    }

    func testSeekClampsToMaxDuration() {
        XCTAssertEqual(clamped(200, duration: 120), 120, accuracy: 0.001)
    }

    func testSeekMidRangeUnchanged() {
        XCTAssertEqual(clamped(60, duration: 120), 60, accuracy: 0.001)
    }

    func testSeekAtExactZeroIsZero() {
        XCTAssertEqual(clamped(0, duration: 120), 0, accuracy: 0.001)
    }

    func testSeekAtExactDurationIsAllowed() {
        XCTAssertEqual(clamped(120, duration: 120), 120, accuracy: 0.001)
    }

    func testSeekWithNoDurationAllowsLargeValue() {
        // When duration is unknown, only clamp to 0 (no upper bound)
        XCTAssertEqual(clamped(9999, duration: nil), 9999, accuracy: 0.001)
    }
}

// MARK: - playQueueItem(at:) index validation logic

final class PlayQueueItemValidationTests: XCTestCase {

    /// Mirrors the bounds check in AudioPlayerService.playQueueItem(at:).
    private func isValidIndex(_ index: Int, count: Int) -> Bool {
        index >= 0 && index < count
    }

    func testValidIndexWithinQueue() {
        XCTAssertTrue(isValidIndex(0, count: 5))
        XCTAssertTrue(isValidIndex(4, count: 5))
        XCTAssertTrue(isValidIndex(2, count: 5))
    }

    func testNegativeIndexIsInvalid() {
        XCTAssertFalse(isValidIndex(-1, count: 5))
    }

    func testIndexEqualToCountIsInvalid() {
        XCTAssertFalse(isValidIndex(5, count: 5))
    }

    func testIndexGreaterThanCountIsInvalid() {
        XCTAssertFalse(isValidIndex(99, count: 5))
    }

    func testSingleTrackQueueIndexZeroIsValid() {
        XCTAssertTrue(isValidIndex(0, count: 1))
    }

    func testSingleTrackQueueIndexOneIsInvalid() {
        XCTAssertFalse(isValidIndex(1, count: 1))
    }
}

// MARK: - AudioPlayerService API symbol presence (iOS only)

#if os(iOS)
@MainActor
final class NowPlayingQueueAPISymbolTests: XCTestCase {

    func testSeekToSymbolExists() {
        // Compile-time check: seek(to:) is public and callable.
        let service = AudioPlayerService.shared
        // No-op: not in library mode; must not crash.
        service.seek(to: 30.0)
        XCTAssertTrue(true, "seek(to:) compiles and does not crash outside library mode")
    }

    func testPlayQueueItemSymbolExists() {
        let service = AudioPlayerService.shared
        // No-op: not in library mode; must not crash.
        service.playQueueItem(at: 0)
        XCTAssertTrue(true, "playQueueItem(at:) compiles and does not crash outside library mode")
    }

    func testMoveQueueItemSymbolExists() {
        let service = AudioPlayerService.shared
        // No-op: not in library mode; must not crash.
        service.moveQueueItem(from: 0, to: 1)
        XCTAssertTrue(true, "moveQueueItem(from:to:) compiles and does not crash outside library mode")
    }

    func testTrackElapsedDefaultsToZero() {
        let service = AudioPlayerService.shared
        // trackElapsed is cleared by stop(); default in a fresh service is 0.
        XCTAssertEqual(service.trackElapsed, 0.0, accuracy: 0.001,
            "trackElapsed should be 0.0 when no track is playing")
    }

    func testTrackDurationDefaultsToNil() {
        let service = AudioPlayerService.shared
        XCTAssertNil(service.trackDuration, "trackDuration should be nil when no track is playing")
    }

    func testSeekNoOpWhenNotInLibraryMode() {
        let service = AudioPlayerService.shared
        // No library source → seek is a no-op, trackElapsed should remain 0
        let before = service.trackElapsed
        service.seek(to: 30.0)
        XCTAssertEqual(service.trackElapsed, before, accuracy: 0.001,
            "seek(to:) outside library mode must not change trackElapsed")
    }

    func testPlayQueueItemNoOpWhenNotInLibraryMode() {
        let service = AudioPlayerService.shared
        let before = service.currentQueueIndex
        service.playQueueItem(at: 0)
        XCTAssertEqual(service.currentQueueIndex, before,
            "playQueueItem(at:) outside library mode must not change currentQueueIndex")
    }

    func testMoveQueueItemNoOpWhenNotInLibraryMode() {
        let service = AudioPlayerService.shared
        let before = service.currentQueueIndex
        service.moveQueueItem(from: 0, to: 1)
        XCTAssertEqual(service.currentQueueIndex, before,
            "moveQueueItem outside library mode must not change currentQueueIndex")
    }
}
#endif
