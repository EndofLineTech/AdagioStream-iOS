import XCTest
@testable import AdagioStream

// f0d — state-observed initial seek trigger: fire when VLC is seekable with a
// known length, or once the bounded fallback deadline passes.
final class AudiobookSeekTriggerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000)

    func testFiresWhenSeekableAndLengthKnown() {
        XCTAssertTrue(AudioPlayerService.shouldApplyAudiobookSeek(
            isSeekable: true, hasLength: true, now: now, deadline: now.addingTimeInterval(5)))
    }

    func testWaitsWhenNotYetSeekable() {
        XCTAssertFalse(AudioPlayerService.shouldApplyAudiobookSeek(
            isSeekable: false, hasLength: true, now: now, deadline: now.addingTimeInterval(5)))
    }

    func testWaitsWhenLengthUnknown() {
        XCTAssertFalse(AudioPlayerService.shouldApplyAudiobookSeek(
            isSeekable: true, hasLength: false, now: now, deadline: now.addingTimeInterval(5)))
    }

    func testFallbackFiresAtDeadlineEvenIfNotReady() {
        XCTAssertTrue(AudioPlayerService.shouldApplyAudiobookSeek(
            isSeekable: false, hasLength: false, now: now, deadline: now))
    }
}
