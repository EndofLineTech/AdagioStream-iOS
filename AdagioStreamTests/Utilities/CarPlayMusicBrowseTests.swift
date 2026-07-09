// CarPlayMusicBrowseTests.swift
//
// Unit tests for the pure-logic helpers added to CarPlayTemplateManager.
//   8rg.1: formatDuration
//   8rg.2: shuffleButtonSelected / repeatButtonSelected button-state mapping
//   j7d.3: upNextRowDetail — row label logic for the Up Next queue list
//
// CarPlay UI itself can't be exercised in the simulator (no CPInterfaceController
// without a real CarPlay connection), but these static helpers are
// framework-free and fully testable here.
//
// Gated #if os(iOS) because CarPlay is iOS-only.

#if os(iOS)
import XCTest
@testable import AdagioStream

final class CarPlayMusicBrowseTests: XCTestCase {

    // MARK: - formatDuration (8rg.1)

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

    // MARK: - shuffleButtonSelected (8rg.2)

    func testShuffleButtonSelectedWhenEnabled() {
        // The CarPlay shuffle button should appear highlighted when shuffle is on.
        XCTAssertTrue(
            CarPlayTemplateManager.shuffleButtonSelected(shuffleEnabled: true),
            "Shuffle button should be selected when shuffle is enabled"
        )
    }

    func testShuffleButtonNotSelectedWhenDisabled() {
        // The CarPlay shuffle button should NOT appear highlighted when shuffle is off.
        XCTAssertFalse(
            CarPlayTemplateManager.shuffleButtonSelected(shuffleEnabled: false),
            "Shuffle button should not be selected when shuffle is disabled"
        )
    }

    // MARK: - repeatButtonSelected (8rg.2)

    func testRepeatButtonNotSelectedWhenOff() {
        // .off → no repeat active → button not highlighted.
        XCTAssertFalse(
            CarPlayTemplateManager.repeatButtonSelected(repeatMode: .off),
            "Repeat button should not be selected when repeatMode is .off"
        )
    }

    func testRepeatButtonSelectedWhenAll() {
        // .all → repeat active → button highlighted.
        XCTAssertTrue(
            CarPlayTemplateManager.repeatButtonSelected(repeatMode: .all),
            "Repeat button should be selected when repeatMode is .all"
        )
    }

    func testRepeatButtonSelectedWhenOne() {
        // .one → repeat active → button highlighted.
        XCTAssertTrue(
            CarPlayTemplateManager.repeatButtonSelected(repeatMode: .one),
            "Repeat button should be selected when repeatMode is .one"
        )
    }

    func testRepeatButtonCycleOrder() {
        // Verify the full cycle: .off → .all → .one → .off
        // (the mapping used by cycleRepeatMode()).
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    // MARK: - upNextRowDetail (j7d.3)

    func testUpNextRowDetailCurrentTrack() {
        // The currently-playing track shows "Now Playing" regardless of duration.
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 2, currentIndex: 2, duration: 225),
            "Now Playing",
            "Currently-playing track should show 'Now Playing'"
        )
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 0, currentIndex: 0, duration: nil),
            "Now Playing",
            "Currently-playing track with no duration should still show 'Now Playing'"
        )
    }

    func testUpNextRowDetailOtherTrackWithDuration() {
        // A non-playing track with a known duration shows the formatted duration.
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 1, currentIndex: 0, duration: 225),
            "3:45",
            "Non-playing track with duration should show formatted duration"
        )
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 3, currentIndex: 0, duration: 3661),
            "1:01:01",
            "Non-playing track with hour-range duration should format correctly"
        )
    }

    func testUpNextRowDetailOtherTrackNoDuration() {
        // A non-playing track with no duration returns nil.
        XCTAssertNil(
            CarPlayTemplateManager.upNextRowDetail(index: 1, currentIndex: 0, duration: nil),
            "Non-playing track with no duration should return nil detail"
        )
    }

    func testUpNextRowDetailNoCurrentIndex() {
        // When currentIndex is nil (queue not fully initialized), no "Now Playing" label.
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 0, currentIndex: nil, duration: 60),
            "1:00",
            "With no currentIndex, row shows duration"
        )
        XCTAssertNil(
            CarPlayTemplateManager.upNextRowDetail(index: 0, currentIndex: nil, duration: nil),
            "With no currentIndex and no duration, row detail is nil"
        )
    }

    // MARK: - audiobookRowDetail (ciu.1)

    private func makeBook(author: String?, progress: Double, isFinished: Bool) -> Audiobook {
        Audiobook(
            id: "b1", libraryItemId: "b1", libraryId: "lib1", title: "A Book",
            author: author, progress: progress, isFinished: isFinished, updatedAt: 0
        )
    }

    func testAudiobookRowDetailAuthorAndProgress() {
        let book = makeBook(author: "Ursula K. Le Guin", progress: 0.42, isFinished: false)
        XCTAssertEqual(
            CarPlayTemplateManager.audiobookRowDetail(book),
            "Ursula K. Le Guin · 42% listened"
        )
    }

    func testAudiobookRowDetailFinishedWins() {
        // Finished takes precedence over a progress percentage.
        let book = makeBook(author: "Author", progress: 0.9, isFinished: true)
        XCTAssertEqual(CarPlayTemplateManager.audiobookRowDetail(book), "Author · Finished")
    }

    func testAudiobookRowDetailAuthorOnlyWhenUnstarted() {
        let book = makeBook(author: "Author", progress: 0, isFinished: false)
        XCTAssertEqual(CarPlayTemplateManager.audiobookRowDetail(book), "Author")
    }

    func testAudiobookRowDetailProgressOnlyWhenNoAuthor() {
        let book = makeBook(author: nil, progress: 0.5, isFinished: false)
        XCTAssertEqual(CarPlayTemplateManager.audiobookRowDetail(book), "50% listened")
    }

    func testAudiobookRowDetailEmptyAuthorTreatedAsNil() {
        let book = makeBook(author: "", progress: 0, isFinished: false)
        XCTAssertNil(CarPlayTemplateManager.audiobookRowDetail(book))
    }
}
#endif
