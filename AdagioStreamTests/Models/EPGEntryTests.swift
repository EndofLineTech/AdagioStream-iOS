import AdagioStreamCore
import XCTest
@testable import AdagioStream

final class EPGEntryTests: XCTestCase {

    private func makeEntry(startOffset: TimeInterval, endOffset: TimeInterval) -> EPGEntry {
        let now = Date()
        return EPGEntry(
            channelID: "test",
            title: "Test Show",
            description: "A test entry",
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(endOffset)
        )
    }

    // MARK: - isCurrentlyAiring

    func testIsCurrentlyAiringWhenNowIsBetweenStartAndEnd() {
        let entry = makeEntry(startOffset: -1800, endOffset: 1800) // started 30min ago, ends in 30min
        XCTAssertTrue(entry.isCurrentlyAiring)
    }

    func testIsCurrentlyAiringFalseWhenInPast() {
        let entry = makeEntry(startOffset: -7200, endOffset: -3600) // 2h ago to 1h ago
        XCTAssertFalse(entry.isCurrentlyAiring)
    }

    func testIsCurrentlyAiringFalseWhenInFuture() {
        let entry = makeEntry(startOffset: 3600, endOffset: 7200) // 1h from now to 2h from now
        XCTAssertFalse(entry.isCurrentlyAiring)
    }

    // MARK: - isUpcoming

    func testIsUpcomingWhenStartIsInFuture() {
        let entry = makeEntry(startOffset: 3600, endOffset: 7200)
        XCTAssertTrue(entry.isUpcoming)
    }

    func testIsUpcomingFalseWhenAlreadyStarted() {
        let entry = makeEntry(startOffset: -1800, endOffset: 1800)
        XCTAssertFalse(entry.isUpcoming)
    }

    // MARK: - durationMinutes

    func testDurationMinutesCalculatesCorrectly() {
        let entry = makeEntry(startOffset: 0, endOffset: 5400) // 90 minutes
        XCTAssertEqual(entry.durationMinutes, 90)
    }

    func testDurationMinutesForShortShow() {
        let entry = makeEntry(startOffset: 0, endOffset: 1800) // 30 minutes
        XCTAssertEqual(entry.durationMinutes, 30)
    }
}
