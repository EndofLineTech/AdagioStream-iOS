import XCTest
@testable import AdagioStream

// Audiobookshelf E2 / yu8.3 — progress-sync payload + resume-position logic.
// The smallest checks that fail if the resume precedence or timeListened delta
// break. (Network sync/close is exercised only against a live server.)

@MainActor
final class AudiobookSyncTests: XCTestCase {

    // MARK: - Resume precedence

    func testResumePrefersExplicitOverride() {
        let r = AudioPlayerService.resumePosition(override: 900, sessionCurrentTime: 500, bookCurrentTime: 100)
        XCTAssertEqual(r, 900, accuracy: 0.001)
    }

    func testResumeFallsBackToSessionCurrentTime() {
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: 500, bookCurrentTime: 100)
        XCTAssertEqual(r, 500, accuracy: 0.001, "server /play currentTime is the resume point")
    }

    func testResumeFallsBackToBookRecordWhenServerNil() {
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: nil, bookCurrentTime: 100)
        XCTAssertEqual(r, 100, accuracy: 0.001)
    }

    func testResumeZeroFromScratch() {
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: nil, bookCurrentTime: 0)
        XCTAssertEqual(r, 0, accuracy: 0.001)
    }

    // MARK: - timeListened delta

    func testTimeListenedIsForwardDelta() {
        XCTAssertEqual(AudioPlayerService.timeListened(sinceLastSynced: 100, currentGlobal: 120), 20, accuracy: 0.001)
    }

    func testTimeListenedClampsBackwardSeekToZero() {
        // Seeking backward must never report negative listen time.
        XCTAssertEqual(AudioPlayerService.timeListened(sinceLastSynced: 200, currentGlobal: 150), 0, accuracy: 0.001)
    }

    func testTimeListenedZeroWhenNoProgress() {
        XCTAssertEqual(AudioPlayerService.timeListened(sinceLastSynced: 300, currentGlobal: 300), 0, accuracy: 0.001)
    }
}
