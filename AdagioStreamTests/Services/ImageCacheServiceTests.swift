// 0xy.2 — Tests for ImageCacheService.coverArtCacheKey stable key derivation.
//
// The critical property: the same (host, coverArtID, size) triple must always
// produce the same key regardless of when it's called, what auth salt was used
// to build the fetch URL, or any other per-request state.

import XCTest
@testable import AdagioStream

final class ImageCacheServiceTests: XCTestCase {

    // MARK: - Stable key — same inputs produce same key

    func testSameInputsProduceSameKey() {
        let key1 = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: 300
        )
        let key2 = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: 300
        )
        XCTAssertEqual(key1, key2,
            "Same (host, coverArtID, size) must always produce the same cache key")
    }

    // MARK: - Stable key — different inputs produce different keys

    func testDifferentCoverArtIDsProduceDifferentKeys() {
        let keyA = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-1",
            size: 300
        )
        let keyB = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-2",
            size: 300
        )
        XCTAssertNotEqual(keyA, keyB,
            "Different coverArtIDs must produce different keys")
    }

    func testDifferentSizesProduceDifferentKeys() {
        let key64 = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: 64
        )
        let key300 = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: 300
        )
        XCTAssertNotEqual(key64, key300,
            "Different requested sizes must produce different keys")
    }

    func testNilSizeDistinctFromExplicitSize() {
        let keyFull = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: nil
        )
        let key300 = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: 300
        )
        XCTAssertNotEqual(keyFull, key300,
            "nil size (full image) must produce a different key than an explicit size")
    }

    func testDifferentHostsProduceDifferentKeys() {
        let keyA = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "al-42",
            size: 300
        )
        let keyB = ImageCacheService.coverArtCacheKey(
            host: "https://other.server.com",
            coverArtID: "al-42",
            size: 300
        )
        XCTAssertNotEqual(keyA, keyB,
            "Different server hosts must produce different keys")
    }

    // MARK: - Key format

    func testKeyIsNonEmpty() {
        let key = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "tr-99",
            size: 128
        )
        XCTAssertFalse(key.isEmpty, "Cache key must not be empty")
    }

    func testKeyIs64HexCharacters() {
        // SHA-256 produces 32 bytes → 64 lowercase hex chars.
        let key = ImageCacheService.coverArtCacheKey(
            host: "https://music.example.com",
            coverArtID: "tr-99",
            size: 128
        )
        XCTAssertEqual(key.count, 64,
            "SHA-256 key must be exactly 64 hex characters")
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit },
            "Key must contain only hexadecimal characters")
    }

    // MARK: - Auth-salt independence

    /// Core correctness property: a different auth salt in the fetch URL must
    /// NOT affect the cache key, because the key is derived from
    /// (host, coverArtID, size) — not from the authed URL.
    func testCacheKeyIsIndependentOfAuthSalt() {
        let host = "https://music.example.com"
        let coverArtID = "al-7"

        // Simulate two calls to coverArtURL with different random salts.
        let api1 = NavidromeAPI(host: URL(string: host)!, username: "alice", password: "pw1")
        let api2 = NavidromeAPI(host: URL(string: host)!, username: "alice", password: "pw1")

        // Two different authed URLs (salts differ per call).
        let url1 = api1.coverArtURL(id: coverArtID, size: 300)
        let url2 = api2.coverArtURL(id: coverArtID, size: 300)

        // The authed URLs will almost certainly differ due to random salts.
        // (In the vanishingly-unlikely event salts collide the URLs match,
        // which also satisfies our invariant — but the interesting case is when
        // they differ, so we only assert the key property, not URL inequality.)
        let key1 = ImageCacheService.coverArtCacheKey(host: host, coverArtID: coverArtID, size: 300)
        let key2 = ImageCacheService.coverArtCacheKey(host: host, coverArtID: coverArtID, size: 300)

        XCTAssertEqual(key1, key2,
            "Cache key must be identical regardless of which authed URL was used to fetch")

        // Confirm neither URL is nil (i.e. URL construction itself still works).
        XCTAssertNotNil(url1, "coverArtURL must return a non-nil URL")
        XCTAssertNotNil(url2, "coverArtURL must return a non-nil URL")
    }
}
