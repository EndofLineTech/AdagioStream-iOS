import XCTest
@testable import AdagioStream

/// Baseline characterization for `PersistenceService` and the Codable
/// round-trip of every model that consumes it. Path stability is verified
/// across a `PersistenceService.shared` access (singleton, so it persists
/// for the duration of the test process — a subsequent process would
/// land in the same `<application support>/Adagio Stream/` directory by
/// construction).
final class PersistenceServiceTests: XCTestCase {

    // MARK: - Codable round-trips

    func testChannelRoundTrip() throws {
        let original = Channel(
            id: "ch.1",
            name: "Test Channel",
            streamURL: URL(string: "https://example.com/stream.ts")!,
            logoURL: URL(string: "https://example.com/logo.png")!,
            group: "News",
            epgChannelID: "epg.1",
            isFavorite: true,
            providerName: "Test Provider",
            isCustomPlaylist: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Channel.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEPGEntryRoundTrip() throws {
        let original = EPGEntry(
            channelID: "epg.1",
            title: "Morning News",
            description: "Daily roundup",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EPGEntry.self, from: data)
        XCTAssertEqual(decoded.channelID, original.channelID)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.start, original.start)
        XCTAssertEqual(decoded.end, original.end)
    }

    func testSavedSongRoundTrip() throws {
        let original = SavedSong(
            id: UUID(),
            trackID: "t.1",
            title: "Song",
            artists: ["Artist"],
            artworkURLString: "https://example.com/art.jpg",
            channelName: "Channel",
            channelLogoURLString: nil,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSong.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
    }

    func testCustomPlaylistRoundTrip() throws {
        let entry = CustomPlaylistEntry(
            name: "Manual Channel",
            streamURL: URL(string: "https://example.com/s.m3u8")!
        )
        let group = CustomPlaylistGroup(name: "Group A", entries: [entry])
        let original = CustomPlaylist(name: "My Playlist", groups: [group])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomPlaylist.self, from: data)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.groups.count, 1)
        XCTAssertEqual(decoded.groups[0].entries.count, 1)
        XCTAssertEqual(decoded.groups[0].entries[0].name, "Manual Channel")
    }

    func testAppSettingsDefaultRoundTrip() throws {
        let original = AppSettings.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.bufferDuration, original.bufferDuration)
        XCTAssertEqual(decoded.appearanceMode, original.appearanceMode)
        XCTAssertEqual(decoded.channelSortOrder, original.channelSortOrder)
    }

    // MARK: - PersistenceService path stability

    func testBaseDirectoryURLIsAdagioStream() async {
        let url = await PersistenceService.shared.baseDirectoryURL()
        // Path must end in "Adagio Stream" (Constants.appName) — locked
        // byte-identical to legacy iOS persistence path.
        XCTAssertEqual(url.lastPathComponent, "Adagio Stream")
    }

    func testRoundTripThroughDisk() async throws {
        let testFilename = "characterization-roundtrip.json"
        let payload = ["a", "b", "c"]
        try await PersistenceService.shared.save(payload, to: testFilename)
        let loaded: [String] = try await PersistenceService.shared.load(from: testFilename)
        XCTAssertEqual(loaded, payload)
        await PersistenceService.shared.delete(testFilename)
    }
}

final class AppSettingsSXMGroupSelectionTests: XCTestCase {
    func testExactRawGroupNamesRoundTripWithoutNormalization() throws {
        var settings = AppSettings.default
        settings.selectedSXMGroupNames = [
            "SiriusXM",
            "siriusxm",
            " SiriusXM ",
            "SiriusXM: Rock & Roll"
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.selectedSXMGroupNames, settings.selectedSXMGroupNames)
    }

    func testSameExactGroupNameHasOneStoredIdentity() throws {
        var settings = AppSettings.default
        settings.selectedSXMGroupNames = Set(["SiriusXM", "SiriusXM"])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.selectedSXMGroupNames, ["SiriusXM"])
    }

    func testExplicitEmptySelectionRoundTripsAsCompletedChoice() throws {
        let settings = AppSettings.default

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertNotNil(object["selectedSXMGroupNames"])
        XCTAssertEqual(decoded.selectedSXMGroupNames, [])
        XCTAssertTrue(decoded.hasCompletedSXMGroupSelectionMigration)
    }

    func testMigrationCompletionStateRoundTrips() throws {
        var settings = AppSettings.default
        settings.hasCompletedSXMGroupSelectionMigration = false

        let pendingData = try JSONEncoder().encode(settings)
        let pending = try JSONDecoder().decode(AppSettings.self, from: pendingData)
        XCTAssertFalse(pending.hasCompletedSXMGroupSelectionMigration)

        settings.hasCompletedSXMGroupSelectionMigration = true
        let completedData = try JSONEncoder().encode(settings)
        let completed = try JSONDecoder().decode(AppSettings.self, from: completedData)
        XCTAssertTrue(completed.hasCompletedSXMGroupSelectionMigration)
    }

    func testLegacySettingsWithoutSelectionStateDecodeAsMigrationPending() throws {
        let encodedDefaults = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedDefaults) as? [String: Any])
        object.removeValue(forKey: "selectedSXMGroupNames")
        object.removeValue(forKey: "hasCompletedSXMGroupSelectionMigration")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.selectedSXMGroupNames, [])
        XCTAssertFalse(decoded.hasCompletedSXMGroupSelectionMigration)
    }
}
