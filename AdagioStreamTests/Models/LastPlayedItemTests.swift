// LastPlayedItemTests.swift
//
// beads_mobilemusic-cpr kickback (Warn): CarPlay reconnect-resume's
// "last played" option must resume the previously playing ITEM — channel,
// audiobook, or library track — not just radio channels. These tests cover
// the typed persistence round-trip for all three cases, plus overwrite and
// clear semantics, using a dedicated UserDefaults suite so this test doesn't
// clobber (or get clobbered by) real app state or other tests.

import XCTest
@testable import AdagioStream

final class LastPlayedItemTests: XCTestCase {

    override func tearDown() {
        LastPlayedItem.clear()
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
