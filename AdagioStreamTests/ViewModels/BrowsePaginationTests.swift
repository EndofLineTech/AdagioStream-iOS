// uxc.2 — Pure pagination-decision tests for BrowsePagination.
//
// Covers `hasMore` (full-page heuristic, since Subsonic's getAlbumList2 /
// getSongsByGenre / search3 return no total count) and `shouldLoadMore`
// (the last-item + not-already-loading gate that drives infinite scroll).

import XCTest
@testable import AdagioStream

final class BrowsePaginationTests: XCTestCase {

    // MARK: - hasMore

    func testHasMoreTrueWhenReturnedCountMatchesPageSize() {
        XCTAssertTrue(BrowsePagination.hasMore(returnedCount: 50, requestedPageSize: 50))
    }

    func testHasMoreTrueWhenReturnedCountExceedsPageSize() {
        // Defensive: a server that ignores the requested size shouldn't wedge us into "no more".
        XCTAssertTrue(BrowsePagination.hasMore(returnedCount: 60, requestedPageSize: 50))
    }

    func testHasMoreFalseWhenReturnedCountBelowPageSize() {
        XCTAssertFalse(BrowsePagination.hasMore(returnedCount: 12, requestedPageSize: 50))
    }

    func testHasMoreFalseWhenReturnedCountIsZero() {
        XCTAssertFalse(BrowsePagination.hasMore(returnedCount: 0, requestedPageSize: 50))
    }

    func testHasMoreFalseWhenPageSizeIsZero() {
        XCTAssertFalse(BrowsePagination.hasMore(returnedCount: 0, requestedPageSize: 0))
    }

    // MARK: - shouldLoadMore

    func testShouldLoadMoreTrueForLastItemWithMoreAndNotLoading() {
        XCTAssertTrue(BrowsePagination.shouldLoadMore(
            itemID: "last", lastItemID: "last", hasMore: true, isLoadingMore: false
        ))
    }

    func testShouldLoadMoreFalseWhenNotTheLastItem() {
        XCTAssertFalse(BrowsePagination.shouldLoadMore(
            itemID: "middle", lastItemID: "last", hasMore: true, isLoadingMore: false
        ))
    }

    func testShouldLoadMoreFalseWhenNoMorePagesExist() {
        XCTAssertFalse(BrowsePagination.shouldLoadMore(
            itemID: "last", lastItemID: "last", hasMore: false, isLoadingMore: false
        ))
    }

    func testShouldLoadMoreFalseWhenAlreadyLoading() {
        // Guards against duplicate concurrent fetches as the list re-renders
        // mid-fetch (the new page's last item still equals the old one until it lands).
        XCTAssertFalse(BrowsePagination.shouldLoadMore(
            itemID: "last", lastItemID: "last", hasMore: true, isLoadingMore: true
        ))
    }

    func testShouldLoadMoreFalseWhenListIsEmpty() {
        XCTAssertFalse(BrowsePagination.shouldLoadMore(
            itemID: "x", lastItemID: nil, hasMore: true, isLoadingMore: false
        ))
    }
}
