// t96.24 — Shared test fixtures.
//
// `makeTrack` and `makeStore` were each hand-duplicated across several test
// files with the same shape (5x for Track, 3x for NavidromeStore). This file
// centralizes both so new tests reuse them instead of re-typing a fixture.

import XCTest
import GRDB
@testable import AdagioStream

/// Builds a `Track` fixture with sensible defaults for the common case.
/// Matches the shape duplicated across PlaybackQueueTests (x2),
/// InterruptionRecoveryTests, NowPlayingQueueUITests, and ShuffleRepeatTests.
func makeTrack(
    id: String,
    title: String,
    artistId: String = "art-1",
    updatedAt: Int = 0
) -> Track {
    Track(id: id, albumId: "alb-1", artistId: artistId, title: title, updatedAt: updatedAt)
}

/// Returns a fresh in-memory `NavidromeStore` with all migrations applied.
/// Matches the `makeStore()` helper duplicated in NavidromeStoreTests,
/// NavidromeModelsTests, and DownloadManagerTests.
func makeInMemoryNavidromeStore() throws -> NavidromeStore {
    try NavidromeStore(writer: try DatabaseQueue())
}
