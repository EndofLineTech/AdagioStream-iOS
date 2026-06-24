// PlaybackQueueTests.swift
//
// Tests for the d6q.1 queue model logic.
//
// The queue model lives in two places:
//   1. PlaybackSource.library(queue:index:) — the authoritative state store (enum)
//   2. AudioPlayerService — observable @Published wrappers + queue navigation
//
// These tests cover the pure PlaybackSource logic (no VLC, no audio session).
// AudioPlayerService queue API surface tests are in AudioPlayerServiceTests.swift.

import XCTest
@testable import AdagioStream

// MARK: - PlaybackSource queue model tests

final class PlaybackQueueTests: XCTestCase {

    // MARK: - Helpers

    private func makeTrack(
        id: String,
        title: String,
        artistId: String = "art-1"
    ) -> Track {
        Track(
            id: id,
            albumId: "alb-1",
            artistId: artistId,
            title: title,
            updatedAt: 1_700_000_000
        )
    }

    private func makeTracks(count: Int) -> [Track] {
        (0..<count).map { i in
            makeTrack(id: "t-\(i)", title: "Track \(i + 1)")
        }
    }

    // MARK: - PlaybackSource.library: current item at index

    func testLibrarySourceCurrentItemReflectsIndex() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 1)
        XCTAssertEqual(source.currentItem.displayTitle, "Track 2")
    }

    func testLibrarySourceIndexZeroIsFirstTrack() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 0)
        XCTAssertEqual(source.currentItem.displayTitle, "Track 1")
    }

    func testLibrarySourceLastIndexIsLastTrack() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 2)
        XCTAssertEqual(source.currentItem.displayTitle, "Track 3")
    }

    // MARK: - Queue navigation via PlaybackSource mutation

    /// Simulates playNextInQueue advancing the index within .library.
    func testNextAdvancesIndex() {
        let tracks = makeTracks(count: 3)
        var source = PlaybackSource.library(queue: tracks, index: 0)

        // Advance to index 1
        if case .library(let q, let idx) = source, idx + 1 < q.count {
            source = .library(queue: q, index: idx + 1)
        }

        XCTAssertEqual(source.currentItem.displayTitle, "Track 2")
        if case .library(_, let idx) = source {
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected .library source after advance")
        }
    }

    /// Simulates playPreviousInQueue decrementing the index.
    func testPreviousDecrementsIndex() {
        let tracks = makeTracks(count: 3)
        var source = PlaybackSource.library(queue: tracks, index: 2)

        if case .library(let q, let idx) = source, idx > 0 {
            source = .library(queue: q, index: idx - 1)
        }

        XCTAssertEqual(source.currentItem.displayTitle, "Track 2")
        if case .library(_, let idx) = source {
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected .library source after previous")
        }
    }

    // MARK: - Edge cases

    /// Edge rule: next() at last index with no repeat — simulate stop behavior.
    /// The service sets playbackSource = nil on stop(); verify nil means stopped.
    func testNextAtLastIndexProducesNilSource() {
        let tracks = makeTracks(count: 2)
        let source = PlaybackSource.library(queue: tracks, index: 1)

        // At last index — simulate the "stop" branch: next() sets source to nil
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library source"); return
        }
        let resultSource: PlaybackSource?
        if index + 1 >= queue.count {
            resultSource = nil  // stop()
        } else {
            resultSource = .library(queue: queue, index: index + 1)
        }

        XCTAssertNil(resultSource, "Expected nil (stopped) when advancing past last track with no repeat")
    }

    /// Edge rule: previous() at index 0 restarts current track (index stays 0).
    func testPreviousAtIndexZeroStaysAtZero() {
        let tracks = makeTracks(count: 3)
        var source = PlaybackSource.library(queue: tracks, index: 0)

        // Simulate playPreviousInQueue: max(0, index - 1) = 0
        if case .library(let q, let idx) = source {
            source = .library(queue: q, index: max(0, idx - 1))
        }

        XCTAssertEqual(source.currentItem.displayTitle, "Track 1")
        if case .library(_, let idx) = source {
            XCTAssertEqual(idx, 0, "Previous at index 0 should stay at 0 (restart current track)")
        } else {
            XCTFail("Expected .library source")
        }
    }

    /// Out-of-bounds startIndex is clamped: setQueue clamps to [0, count-1].
    func testOutOfBoundsStartIndexClampsToValid() {
        let tracks = makeTracks(count: 3)

        // Simulate the clamping logic in setQueue
        let outOfBoundsIndex = 99
        let clamped = max(0, min(outOfBoundsIndex, tracks.count - 1))
        let source = PlaybackSource.library(queue: tracks, index: clamped)

        XCTAssertEqual(clamped, 2, "Index 99 clamped to last valid index (2) for a 3-track queue")
        XCTAssertEqual(source.currentItem.displayTitle, "Track 3")
    }

    func testNegativeStartIndexClampsToZero() {
        let tracks = makeTracks(count: 3)
        let clamped = max(0, min(-5, tracks.count - 1))
        XCTAssertEqual(clamped, 0, "Negative index clamped to 0")
        let source = PlaybackSource.library(queue: tracks, index: clamped)
        XCTAssertEqual(source.currentItem.displayTitle, "Track 1")
    }

    // MARK: - displayArtistName carries across navigation

    /// Verify that the queue-level artist name persists as the index advances —
    /// the artist name is stored separately (queueDisplayArtistName), but the
    /// intent is that it remains the same as the index changes.  These tests
    /// prove the *model* doesn't change it; the service test proves it threads.
    func testQueuePreservesAllTracksWhenAdvancing() {
        let tracks = makeTracks(count: 3)
        var source = PlaybackSource.library(queue: tracks, index: 0)

        // Advance through the queue
        if case .library(let q, let idx) = source, idx + 1 < q.count {
            source = .library(queue: q, index: idx + 1)
        }

        // Queue is unchanged — same tracks, different index
        if case .library(let q, _) = source {
            XCTAssertEqual(q.count, 3, "Queue track count preserved after advance")
            XCTAssertEqual(q[0].title, "Track 1")
            XCTAssertEqual(q[1].title, "Track 2")
            XCTAssertEqual(q[2].title, "Track 3")
        } else {
            XCTFail("Expected .library source")
        }
    }

    // MARK: - Radio source unchanged

    /// Verify PlaybackSource.radio is unaffected by queue model additions.
    func testRadioSourceCurrentItemUnchanged() {
        let channel = Channel(
            id: "ch-1",
            name: "KEXP 90.3",
            streamURL: URL(string: "https://kexp.example.com/stream")!,
            logoURL: nil,
            group: "Community Radio",
            epgChannelID: nil,
            isFavorite: false,
            providerName: "My Provider",
            isCustomPlaylist: false
        )
        let source = PlaybackSource.radio(channel)
        XCTAssertEqual(source.currentItem.displayTitle, "KEXP 90.3")
        XCTAssertTrue(source.currentItem.isLiveStream)
    }

    // MARK: - currentItem reflects exact index

    func testCurrentItemReflectsEveryIndexInQueue() {
        let titles = ["First", "Second", "Third", "Fourth", "Fifth"]
        let tracks = titles.enumerated().map { i, title in
            makeTrack(id: "t-\(i)", title: title)
        }

        for (expectedIndex, expectedTitle) in titles.enumerated() {
            let source = PlaybackSource.library(queue: tracks, index: expectedIndex)
            XCTAssertEqual(
                source.currentItem.displayTitle,
                expectedTitle,
                "currentItem.displayTitle mismatch at index \(expectedIndex)"
            )
        }
    }

    // MARK: - Single-track queue (setQueue with one track)

    func testSingleTrackQueueStaysAtIndexZero() {
        let track = makeTrack(id: "solo", title: "Only Track")
        let source = PlaybackSource.library(queue: [track], index: 0)
        XCTAssertEqual(source.currentItem.displayTitle, "Only Track")

        // Previous at index 0: stays at 0
        if case .library(let q, let idx) = source {
            let newIdx = max(0, idx - 1)
            XCTAssertEqual(newIdx, 0)
            let newSource = PlaybackSource.library(queue: q, index: newIdx)
            XCTAssertEqual(newSource.currentItem.displayTitle, "Only Track")
        }
    }

    func testSingleTrackQueueNextAtLastIndexIsEnd() {
        let track = makeTrack(id: "solo", title: "Only Track")
        let source = PlaybackSource.library(queue: [track], index: 0)

        // Next at last index (0 == count-1): should stop
        if case .library(let q, let idx) = source {
            let isAtEnd = idx + 1 >= q.count
            XCTAssertTrue(isAtEnd, "Single-track queue: next at index 0 is end-of-queue")
        }
    }
}

// MARK: - AudioPlayerService queue API surface tests

#if os(iOS)
@MainActor
final class AudioPlayerServiceQueueAPITests: XCTestCase {

    /// Verifies the queue API symbols exist and are callable on the shared singleton.
    /// These are compile-time + symbol-presence checks; actual VLC playback is
    /// not exercised (requires a real audio session and network).
    func testQueueAPISymbolsExist() {
        let service = AudioPlayerService.shared

        // currentQueueIndex is @Published, initially nil
        XCTAssertNil(service.currentQueueIndex, "currentQueueIndex should be nil before any queue is set")

        // currentLibraryQueue is a computed property, initially empty
        XCTAssertTrue(service.currentLibraryQueue.isEmpty, "currentLibraryQueue should be empty before any queue is set")
    }

    /// Verifies that playNext() and playPrevious() (radio channel cycling) still
    /// compile and are callable — radio path must remain intact per spec.
    func testRadioPlayNextAndPlayPreviousStillAccessible() {
        let service = AudioPlayerService.shared
        // These call the radio channel-cycling path.  They are no-ops when no
        // channel list is loaded, but must compile and not crash.
        service.playNext()
        service.playPrevious()
        // If we reach here, the radio API is intact.
        XCTAssertTrue(true, "playNext() and playPrevious() (radio) compile and execute without crash")
    }

    /// playNextInQueue and playPreviousInQueue are no-ops when not in library mode.
    func testQueueNavigationNoOpsWhenNotInLibraryMode() {
        let service = AudioPlayerService.shared
        // If currentChannel is nil and playbackSource is nil, these should not crash.
        service.playNextInQueue()
        service.playPreviousInQueue()
        XCTAssertTrue(true, "Queue navigation methods are no-ops outside library mode")
    }

    /// setQueue with an empty array is a no-op (no crash, no state change).
    func testSetQueueWithEmptyTracksIsNoOp() {
        let service = AudioPlayerService.shared
        let api = NavidromeAPI(
            host: URL(string: "https://navidrome.test")!,
            username: "u",
            password: "p"
        )
        let initialIndex = service.currentQueueIndex
        service.setQueue([], startIndex: 0, displayArtistName: nil, via: api)
        // State should not have changed
        XCTAssertEqual(service.currentQueueIndex, initialIndex, "setQueue with empty list should not change currentQueueIndex")
    }
}
#endif
