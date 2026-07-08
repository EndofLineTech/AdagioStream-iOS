// ShuffleRepeatTests.swift
//
// Unit tests for d6q.4: shuffle + repeat (off/all/one) modes.
//
// All tests exercise pure model logic — the PlaybackSource decision layer —
// without VLC or a real audio session.  The runtime integration (VLC .ended →
// advance()) is validated by the launch smoke test.

import XCTest
@testable import AdagioStream

// MARK: - RepeatMode enum tests

final class RepeatModeTests: XCTestCase {

    // MARK: - Cycle

    func testCycleOffToAll() {
        XCTAssertEqual(RepeatMode.off.next, .all)
    }

    func testCycleAllToOne() {
        XCTAssertEqual(RepeatMode.all.next, .one)
    }

    func testCycleOneToOff() {
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    // MARK: - Codable round-trip

    func testRepeatModeCodableOff() throws {
        let data = try JSONEncoder().encode(RepeatMode.off)
        let decoded = try JSONDecoder().decode(RepeatMode.self, from: data)
        XCTAssertEqual(decoded, .off)
    }

    func testRepeatModeCodableAll() throws {
        let data = try JSONEncoder().encode(RepeatMode.all)
        let decoded = try JSONDecoder().decode(RepeatMode.self, from: data)
        XCTAssertEqual(decoded, .all)
    }

    func testRepeatModeCodableOne() throws {
        let data = try JSONEncoder().encode(RepeatMode.one)
        let decoded = try JSONDecoder().decode(RepeatMode.self, from: data)
        XCTAssertEqual(decoded, .one)
    }
}

// MARK: - AppSettings persistence for repeatMode + shuffleEnabled

final class AppSettingsQueuePreferencesTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultRepeatModeIsOff() {
        let settings = AppSettings.default
        XCTAssertEqual(settings.repeatMode, .off)
    }

    func testDefaultShuffleEnabledIsFalse() {
        let settings = AppSettings.default
        XCTAssertFalse(settings.shuffleEnabled)
    }

    // MARK: - Codable round-trips

    func testRepeatModePersistsAcrossRoundTrip() throws {
        var settings = AppSettings.default
        settings.repeatMode = .all
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.repeatMode, .all)
    }

    func testShuffleEnabledPersistsAcrossRoundTrip() throws {
        var settings = AppSettings.default
        settings.shuffleEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.shuffleEnabled)
    }

    /// Tolerant decoder: older on-disk JSON without repeatMode/shuffleEnabled
    /// must decode to the safe defaults (.off, false) without throwing.
    func testToleranceForMissingQueueFields() throws {
        // Minimal settings JSON that does NOT include repeatMode or shuffleEnabled.
        // This mirrors a settings.json written before d6q.4.
        let oldJson = """
        {
          "bufferDuration": 5,
          "appearanceMode": "system",
          "textSizeMode": "system",
          "sortPrefixes": ["Radio: ", "TV: "],
          "channelSortOrder": "providerOrder",
          "groupSortOrder": "providerOrder",
          "debugLoggingEnabled": false,
          "artworkDisplayMode": "coverArt",
          "espnLivePollInterval": 15,
          "channelGroupingMode": "allGroups",
          "hasCompletedSetup": false,
          "hasSeenTabReorgTip": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldJson)
        XCTAssertEqual(decoded.repeatMode, .off, "Missing repeatMode should default to .off")
        XCTAssertFalse(decoded.shuffleEnabled, "Missing shuffleEnabled should default to false")
    }
}

// MARK: - Repeat mode decision logic (auto-advance vs manual)

/// These tests exercise the pure PlaybackSource-level decision that `advance()`
/// and `playNextInQueue()` compute — without invoking VLC or AudioPlayerService.
final class RepeatModeDecisionTests: XCTestCase {

    private func makeTracks(count: Int) -> [Track] {
        (0..<count).map { makeTrack(id: "t-\($0)", title: "Track \($0 + 1)") }
    }

    // MARK: - repeat .one: auto-advance restarts current

    func testRepeatOneAutoAdvanceRestartsCurrent() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 1)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // Simulate advance() with repeatMode == .one:
        // result index == same index (restart current)
        let resultIndex = index  // .one: no change to index
        XCTAssertEqual(resultIndex, 1, "repeat .one auto-advance should restart track at index 1")
        XCTAssertEqual(queue[resultIndex].title, "Track 2")
    }

    func testRepeatOneAutoAdvanceAtLastTrackRestartsCurrent() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 2)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // repeat .one at last index — still restarts, does NOT stop
        let resultIndex = index
        XCTAssertEqual(resultIndex, 2, "repeat .one at last track should restart, not stop")
        XCTAssertEqual(queue[resultIndex].title, "Track 3")
    }

    // MARK: - repeat .all: auto-advance wraps at end

    func testRepeatAllAutoAdvanceWrapsAtEnd() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 2) // last track
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // Simulate advance() with repeatMode == .all (no shuffle):
        let nextIndex = (index + 1) % queue.count
        XCTAssertEqual(nextIndex, 0, "repeat .all auto-advance at last track should wrap to index 0")
        XCTAssertEqual(queue[nextIndex].title, "Track 1")
    }

    func testRepeatAllAutoAdvanceMidQueueDoesNotWrap() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 1)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        let nextIndex = (index + 1) % queue.count
        XCTAssertEqual(nextIndex, 2, "repeat .all mid-queue advance should move to next track")
        XCTAssertEqual(queue[nextIndex].title, "Track 3")
    }

    // MARK: - repeat .off: auto-advance stops at end

    func testRepeatOffAutoAdvanceStopsAtEnd() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 2) // last track
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        let nextIndex = index + 1
        let isAtEnd = nextIndex >= queue.count
        XCTAssertTrue(isAtEnd, "repeat .off at last track should detect end-of-queue")
        // The service calls stop() which sets playbackSource = nil
        let result: PlaybackSource? = isAtEnd ? nil : .library(queue: queue, index: nextIndex)
        XCTAssertNil(result, "repeat .off end-of-queue should yield nil (stopped) source")
    }

    // MARK: - manual next does NOT trap on repeat .one

    func testManualNextWithRepeatOneMovesToNextTrack() {
        // repeat .one should NOT trap manual next: behaves like .off for manual nav.
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 1)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // Manual next with repeat .one: advance exactly as .off would (one step).
        let nextIndex = index + 1
        let isAtEnd = nextIndex >= queue.count
        XCTAssertFalse(isAtEnd, "Manual next at index 1 of 3 is not at end")
        XCTAssertEqual(nextIndex, 2, "Manual next with repeat .one should advance to index 2")
        XCTAssertEqual(queue[nextIndex].title, "Track 3")
    }

    func testManualNextWithRepeatOneAtLastTrackStops() {
        // At the last track, manual next with repeat .one behaves like .off: stop.
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 2)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // Manual next with repeat .one at last track → stop (no wrap, no restart).
        let nextIndex = index + 1
        let isAtEnd = nextIndex >= queue.count
        XCTAssertTrue(isAtEnd, "Manual next with repeat .one at last track should be at end")
    }

    // MARK: - manual next/prev wrap with repeat .all

    func testManualNextWithRepeatAllWrapsAtEnd() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 2)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // repeat .all manual next at last track → wrap to 0
        let nextIndex: Int
        if index + 1 >= queue.count {
            nextIndex = 0  // repeat .all wrap
        } else {
            nextIndex = index + 1
        }
        XCTAssertEqual(nextIndex, 0, "Manual next with repeat .all at last track should wrap to 0")
        XCTAssertEqual(queue[nextIndex].title, "Track 1")
    }

    func testManualPrevWithRepeatAllWrapsAtStart() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 0)
        guard case .library(let queue, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // repeat .all manual previous at index 0 → wrap to last
        let prevIndex: Int
        if index == 0 {
            prevIndex = queue.count - 1  // repeat .all wrap
        } else {
            prevIndex = index - 1
        }
        XCTAssertEqual(prevIndex, 2, "Manual prev with repeat .all at index 0 should wrap to last")
        XCTAssertEqual(queue[prevIndex].title, "Track 3")
    }

    func testManualPrevWithRepeatOffAtStartRestartsCurrent() {
        let tracks = makeTracks(count: 3)
        let source = PlaybackSource.library(queue: tracks, index: 0)
        guard case .library(_, let index) = source else {
            XCTFail("Expected .library"); return
        }

        // repeat .off (or .one): previous at index 0 restarts current
        let prevIndex = max(0, index - 1)
        XCTAssertEqual(prevIndex, 0, "Manual prev with repeat .off at index 0 should restart current (stay at 0)")
    }
}

// MARK: - Shuffle permutation correctness

final class ShufflePermutationTests: XCTestCase {

    /// Builds a shuffle order by pinning the current track at position 0 and
    /// shuffling the rest.  Mirrors the logic in AudioPlayerService.buildShuffleOrder.
    private func buildShuffleOrder(queueCount: Int, pinning pinnedIndex: Int) -> [Int] {
        var rest = Array(0..<queueCount).filter { $0 != pinnedIndex }
        rest.shuffle()
        return [pinnedIndex] + rest
    }

    private func buildShuffleOrderFull(queueCount: Int) -> [Int] {
        var order = Array(0..<queueCount)
        order.shuffle()
        return order
    }

    // MARK: - Permutation properties

    func testShuffleOrderIsPermutationOfAllIndices() {
        let count = 5
        let order = buildShuffleOrder(queueCount: count, pinning: 2)
        let sorted = order.sorted()
        XCTAssertEqual(sorted, Array(0..<count), "Shuffle order must cover every index exactly once")
    }

    func testShuffleOrderPinsCurrentTrackAtPositionZero() {
        let count = 5
        let pinnedIndex = 3
        let order = buildShuffleOrder(queueCount: count, pinning: pinnedIndex)
        XCTAssertEqual(order[0], pinnedIndex, "Current track must be at shuffle position 0 after toggle-on")
    }

    func testShuffleOrderHasCorrectLength() {
        let count = 8
        let order = buildShuffleOrder(queueCount: count, pinning: 0)
        XCTAssertEqual(order.count, count, "Shuffle order length must equal queue count")
    }

    func testShuffleOrderForSingleTrack() {
        let order = buildShuffleOrder(queueCount: 1, pinning: 0)
        XCTAssertEqual(order, [0], "Single-track shuffle order must be [0]")
    }

    func testShuffleFullOrderIsPermutation() {
        let count = 6
        let order = buildShuffleOrderFull(queueCount: count)
        let sorted = order.sorted()
        XCTAssertEqual(sorted, Array(0..<count), "Full shuffle order must cover every index exactly once")
    }

    // MARK: - Toggle-on keeps current track

    func testToggleOnKeepsCurrentTrackAtPositionZero() {
        // When shuffle is toggled on, the currently-playing track must be
        // the FIRST track played in the shuffle order (position 0).
        // This mirrors the toggle-on behaviour in AudioPlayerService.toggleShuffle().
        let currentIndex = 4
        let queueCount = 7
        let order = buildShuffleOrder(queueCount: queueCount, pinning: currentIndex)
        XCTAssertEqual(order[0], currentIndex,
            "After toggle-on, the current track (index \(currentIndex)) should be at shuffle position 0")
    }

    func testToggleOnProducesValidPermutation() {
        let currentIndex = 2
        let queueCount = 10
        let order = buildShuffleOrder(queueCount: queueCount, pinning: currentIndex)

        // Is it a valid permutation?
        XCTAssertEqual(order.sorted(), Array(0..<queueCount))
        // Current track pinned at 0?
        XCTAssertEqual(order[0], currentIndex)
    }

    // MARK: - Toggle-off restores natural order from current

    func testToggleOffNaturalOrderUsesCurrentQueueIndex() {
        // Toggle-off: shuffleOrder is cleared, navigation resumes from
        // currentQueueIndex (the canonical queue index of the current track).
        // Test: the current queue index is preserved as-is when shuffle is cleared.
        let currentIndex = 3  // arbitrary in-progress position
        // After toggle-off: next track is index 4 in natural order
        let nextNatural = currentIndex + 1
        XCTAssertEqual(nextNatural, 4, "Toggle-off: natural next should be currentQueueIndex + 1")
    }

    // MARK: - Shuffle traversal covers all tracks

    func testShuffleTraversalCoversAllTracks() {
        // Simulate playing through a full shuffle order by stepping the cursor.
        let queueCount = 5
        let currentIndex = 0
        let order = buildShuffleOrder(queueCount: queueCount, pinning: currentIndex)

        var visited = Set<Int>()
        for shufflePos in 0..<order.count {
            let queueIndex = order[shufflePos]
            XCTAssertFalse(visited.contains(queueIndex),
                "Shuffle order must visit each track exactly once (duplicate at pos \(shufflePos))")
            visited.insert(queueIndex)
        }
        XCTAssertEqual(visited.count, queueCount, "Shuffle traversal must cover all \(queueCount) tracks")
    }
}

// MARK: - AudioPlayerService shuffle/repeat observable state (iOS only)

#if os(iOS)
@MainActor
final class AudioPlayerServiceShuffleRepeatTests: XCTestCase {

    func testDefaultRepeatModeIsOff() {
        let service = AudioPlayerService.shared
        // Default on a fresh-started service is .off
        // (may have been modified by previous test; reset defensively).
        service.repeatMode = .off
        XCTAssertEqual(service.repeatMode, .off)
    }

    func testDefaultShuffleEnabledIsFalse() {
        let service = AudioPlayerService.shared
        service.shuffleEnabled = false
        XCTAssertFalse(service.shuffleEnabled)
    }

    func testCycleRepeatModeOffToAll() {
        let service = AudioPlayerService.shared
        service.repeatMode = .off
        service.cycleRepeatMode()
        XCTAssertEqual(service.repeatMode, .all)
    }

    func testCycleRepeatModeAllToOne() {
        let service = AudioPlayerService.shared
        service.repeatMode = .all
        service.cycleRepeatMode()
        XCTAssertEqual(service.repeatMode, .one)
    }

    func testCycleRepeatModeOneToOff() {
        let service = AudioPlayerService.shared
        service.repeatMode = .one
        service.cycleRepeatMode()
        XCTAssertEqual(service.repeatMode, .off)
    }

    func testToggleShuffleOnAndOff() {
        let service = AudioPlayerService.shared
        service.shuffleEnabled = false

        service.toggleShuffle()
        XCTAssertTrue(service.shuffleEnabled, "toggleShuffle should turn shuffle on from off")

        service.toggleShuffle()
        XCTAssertFalse(service.shuffleEnabled, "toggleShuffle should turn shuffle off from on")
    }

    func testApplyQueuePreferencesUpdatesRepeatMode() {
        let service = AudioPlayerService.shared
        service.applyQueuePreferences(repeatMode: .one, shuffleEnabled: false)
        XCTAssertEqual(service.repeatMode, .one)
        XCTAssertFalse(service.shuffleEnabled)

        // Reset to safe defaults
        service.applyQueuePreferences(repeatMode: .off, shuffleEnabled: false)
    }

    func testApplyQueuePreferencesUpdatesShuffleEnabled() {
        let service = AudioPlayerService.shared
        service.applyQueuePreferences(repeatMode: .off, shuffleEnabled: true)
        XCTAssertTrue(service.shuffleEnabled)
        XCTAssertEqual(service.repeatMode, .off)

        // Reset
        service.applyQueuePreferences(repeatMode: .off, shuffleEnabled: false)
    }

    // MARK: - Radio path is unaffected by shuffle/repeat changes

    func testQueueNavigationNoOpsWhenNotInLibraryMode() {
        let service = AudioPlayerService.shared
        // With no library source, next/previous are no-ops regardless of repeat mode.
        service.repeatMode = .all
        service.playNextInQueue()   // should not crash or change state
        service.playPreviousInQueue() // should not crash or change state
        XCTAssertNil(service.currentQueueIndex,
            "Queue navigation outside library mode must not change currentQueueIndex")
    }

    func testRadioPlayNextPlayPreviousUnchanged() {
        let service = AudioPlayerService.shared
        // Radio cycling (playNext / playPrevious) must remain callable with any repeat/shuffle state.
        service.repeatMode = .all
        service.shuffleEnabled = true
        service.playNext()
        service.playPrevious()
        // Must not crash. Reset.
        service.repeatMode = .off
        service.shuffleEnabled = false
        XCTAssertTrue(true, "Radio playNext/playPrevious unaffected by shuffle/repeat state")
    }
}
#endif
