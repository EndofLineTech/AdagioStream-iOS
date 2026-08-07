// LastPlayedItemTests.swift
//
// beads_mobilemusic-cpr kickback (Warn): CarPlay reconnect-resume's
// "last played" option must resume the previously playing ITEM — channel,
// audiobook, library track, or podcast episode — not just radio channels.
// These tests cover the typed persistence round-trip for all four cases,
// plus overwrite and clear semantics.
//
// Round 2 kickback (Fix 3): `LastPlayedItem.defaults` is a test seam
// (production always uses `.standard`) pointed at a dedicated
// per-test-case UserDefaults suite here, so these tests neither read real
// app state nor leave a `lastPlayedItem` key behind in `.standard` for
// other tests to trip over. The suite is wiped in `tearDown` and the seam
// is restored to `.standard` so no other test file observes the override.

import XCTest
@testable import AdagioStream

final class LastPlayedItemTests: XCTestCase {

    private let suiteName = "LastPlayedItemTests"
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        LastPlayedItem.defaults = suite
    }

    override func tearDown() {
        LastPlayedItem.clear()
        suite.removePersistentDomain(forName: suiteName)
        LastPlayedItem.defaults = .standard
        super.tearDown()
    }

    // MARK: - Round trip per case

    func testChannelRoundTrips() {
        LastPlayedItem.clear()
        LastPlayedItem.channel(id: "ch-1", providerName: "Xtream").save()

        guard case .channel(let id, let providerName) = LastPlayedItem.load() else {
            XCTFail("Expected .channel"); return
        }
        XCTAssertEqual(id, "ch-1")
        XCTAssertEqual(providerName, "Xtream")
    }

    func testChannelRoundTripsWithNilProviderName() {
        LastPlayedItem.clear()
        LastPlayedItem.channel(id: "ch-2", providerName: nil).save()

        guard case .channel(let id, let providerName) = LastPlayedItem.load() else {
            XCTFail("Expected .channel"); return
        }
        XCTAssertEqual(id, "ch-2")
        XCTAssertNil(providerName)
    }

    func testAudiobookRoundTrips() {
        LastPlayedItem.clear()
        LastPlayedItem.audiobook(id: "book-1").save()

        guard case .audiobook(let id) = LastPlayedItem.load() else {
            XCTFail("Expected .audiobook"); return
        }
        XCTAssertEqual(id, "book-1")
    }

    func testLibraryTrackRoundTrips() {
        LastPlayedItem.clear()
        LastPlayedItem.libraryTrack(id: "trk-1", albumId: "alb-1").save()

        guard case .libraryTrack(let id, let albumId) = LastPlayedItem.load() else {
            XCTFail("Expected .libraryTrack"); return
        }
        XCTAssertEqual(id, "trk-1")
        XCTAssertEqual(albumId, "alb-1")
    }

    func testPodcastEpisodeRoundTrips() {
        LastPlayedItem.clear()
        LastPlayedItem.podcastEpisode(showId: "show-1", episodeId: "ep-1").save()

        guard case .podcastEpisode(let showId, let episodeId) = LastPlayedItem.load() else {
            XCTFail("Expected .podcastEpisode"); return
        }
        XCTAssertEqual(showId, "show-1")
        XCTAssertEqual(episodeId, "ep-1")
    }

    // MARK: - Overwrite (whatever played most recently wins)

    func testSavingANewKindOverwritesThePrevious() {
        LastPlayedItem.clear()
        LastPlayedItem.channel(id: "ch-1", providerName: nil).save()
        LastPlayedItem.audiobook(id: "book-1").save()

        guard case .audiobook(let id) = LastPlayedItem.load() else {
            XCTFail("Expected the audiobook write to supersede the earlier channel write"); return
        }
        XCTAssertEqual(id, "book-1")
    }

    // MARK: - Clear / absence

    func testLoadReturnsNilWhenNothingSaved() {
        LastPlayedItem.clear()
        XCTAssertNil(LastPlayedItem.load())
    }

    func testClearRemovesAPreviouslySavedItem() {
        LastPlayedItem.channel(id: "ch-1", providerName: nil).save()
        XCTAssertNotNil(LastPlayedItem.load())

        LastPlayedItem.clear()
        XCTAssertNil(LastPlayedItem.load())
    }
}
