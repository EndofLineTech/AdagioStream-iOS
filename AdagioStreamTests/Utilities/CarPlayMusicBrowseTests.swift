// CarPlayMusicBrowseTests.swift
//
// Unit tests for the pure-logic helpers added to CarPlayTemplateManager in 8rg.1.
// CarPlay UI itself can't be exercised in the simulator (no CPInterfaceController
// without a real CarPlay connection), but the static formatting helper is
// framework-free and fully testable here.
//
// Gated #if os(iOS) because CarPlay is iOS-only.

#if os(iOS)
import XCTest
@testable import AdagioStream

final class CarPlayMusicBrowseTests: XCTestCase {

    // MARK: - formatDuration

    func testFormatDurationSeconds() {
        // Under a minute: no leading hour field
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(0),  "0:00")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(1),  "0:01")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(59), "0:59")
    }

    func testFormatDurationMinutes() {
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(60),  "1:00")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(61),  "1:01")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(90),  "1:30")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(3599), "59:59")
    }

    func testFormatDurationHours() {
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(3600), "1:00:00")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(3661), "1:01:01")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(7323), "2:02:03")
    }

    func testFormatDurationTypicalTrackLength() {
        // 3 min 45 sec = 225 seconds
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(225), "3:45")
        // 4 min 02 sec = 242 seconds
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(242), "4:02")
    }
}
#endif
