// uxc.4 — Truth-table tests for AggregateDownloadState.derive, the pure
// function AlbumDownloadAllButton and playlistDownloadAllButton both use to
// replace their old binary "all downloaded vs. not" state with a determinate
// `.downloading(completed:total:)`.

import XCTest
@testable import AdagioStream

final class AggregateDownloadStateTests: XCTestCase {

    func testEmptyTrackListIsNone() {
        XCTAssertEqual(AggregateDownloadState.derive(statuses: []), .none)
    }

    func testNoTracksDownloadedIsNone() {
        XCTAssertEqual(AggregateDownloadState.derive(statuses: [nil, nil, nil]), .none)
    }

    func testAllCompletedIsAllDownloaded() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.completed, .completed, .completed]),
            .allDownloaded
        )
    }

    func testSomeQueuedIsDownloading() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [nil, .queued, nil]),
            .downloading(completed: 0, total: 3, failed: 0)
        )
    }

    func testSomeDownloadingIsDownloading() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.completed, .downloading, nil]),
            .downloading(completed: 1, total: 3, failed: 0)
        )
    }

    func testSomeFailedCountsTowardNotDoneYetAndIsReportedSeparately() {
        // A failed track still counts toward the total-not-yet-done bucket,
        // but is ALSO surfaced via `failed` (beads_mobilemusic-uxc kickback)
        // so the UI can distinguish "still transferring" from "stalled".
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.completed, .completed, .failed]),
            .downloading(completed: 2, total: 3, failed: 1)
        )
    }

    func testMixOfQueuedDownloadingFailedAndCompletedIsDownloading() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.completed, .queued, .downloading, .failed, .completed]),
            .downloading(completed: 2, total: 5, failed: 1)
        )
    }

    func testAllRemainingTracksFailedReportsFullFailedCount() {
        // Nothing is queued/downloading — every non-completed track is
        // permanently failed. The progress bar looks "stuck" without the
        // failed count; this is the case the kickback fix targets.
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.completed, .failed, .failed]),
            .downloading(completed: 1, total: 3, failed: 2)
        )
    }

    func testPausedCountsTowardNotDoneYet() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.completed, .paused]),
            .downloading(completed: 1, total: 2, failed: 0)
        )
    }

    func testSingleCompletedTrackIsAllDownloaded() {
        XCTAssertEqual(AggregateDownloadState.derive(statuses: [.completed]), .allDownloaded)
    }

    func testSingleQueuedTrackIsDownloading() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.queued]),
            .downloading(completed: 0, total: 1, failed: 0)
        )
    }

    func testSingleFailedTrackReportsFailedCount() {
        XCTAssertEqual(
            AggregateDownloadState.derive(statuses: [.failed]),
            .downloading(completed: 0, total: 1, failed: 1)
        )
    }
}
