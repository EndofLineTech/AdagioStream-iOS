import XCTest
@testable import AdagioStream

// Podcast E2 / 72i.3 — variable playback speed. Supersedes bead alr (no
// separate audiobook-speed work needed; this covers both audiobooks and
// podcasts). Clamping is pure; persistence is a direct UserDefaults
// round-trip — no I/O mocking needed.

@MainActor
final class PlaybackRateTests: XCTestCase {

    override func tearDown() {
        // Leave UserDefaults as found for other tests/launches.
        AudioPlayerService.playbackRate = AudioPlayerService.defaultPlaybackRate
        super.tearDown()
    }

    // MARK: - Clamping

    func testClampLeavesValidRateUnchanged() {
        XCTAssertEqual(AudioPlayerService.clampPlaybackRate(1.5), 1.5)
    }

    func testClampFloorsBelowMinimum() {
        XCTAssertEqual(AudioPlayerService.clampPlaybackRate(0.1), 0.5)
    }

    func testClampCeilsAboveMaximum() {
        XCTAssertEqual(AudioPlayerService.clampPlaybackRate(10.0), 3.0)
    }

    func testClampAtExactBoundsIsUnchanged() {
        XCTAssertEqual(AudioPlayerService.clampPlaybackRate(0.5), 0.5)
        XCTAssertEqual(AudioPlayerService.clampPlaybackRate(3.0), 3.0)
    }

    // MARK: - Persistence round-trip

    func testSetThenReadRoundTrips() {
        AudioPlayerService.playbackRate = 1.75
        XCTAssertEqual(AudioPlayerService.playbackRate, 1.75)
    }

    func testDefaultIsOneWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "abs.playbackRate")
        XCTAssertEqual(AudioPlayerService.playbackRate, 1.0)
    }

    func testStoredValueIsClampedOnWrite() {
        // Setter clamps before persisting, so an out-of-range value can never
        // round-trip back out unclamped.
        AudioPlayerService.playbackRate = 5.0
        XCTAssertEqual(AudioPlayerService.playbackRate, 3.0)
        AudioPlayerService.playbackRate = -1.0
        XCTAssertEqual(AudioPlayerService.playbackRate, 0.5)
    }
}
