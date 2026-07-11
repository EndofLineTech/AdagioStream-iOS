import XCTest
@testable import AdagioStream

/// Tests for the StellarTunerLog (api.stellartunerlog.com/v1) response models,
/// the cut-type displayability blocklist, and the first-observation startedAt/id
/// synthesis. Fixtures mirror live API responses — no network calls.
final class StellarTunerLogModelsTests: XCTestCase {

    // MARK: - Fixtures (captured from the live API)

    private let channelsJSON = """
    {
      "updated_utc": "2026-07-10T08:38:53Z",
      "channel_count": 2,
      "channels": {
        "8184": {
          "id": "8184",
          "name": "Faction Talk",
          "short_name": "FctnTalk",
          "channel_number": 103,
          "sirius_number": 103,
          "description": "Unfiltered talk (explicit)",
          "logos": {
            "color_dark": {"url": "https://example.com/a.png", "width": 900, "height": 720}
          }
        },
        "8206": {
          "id": "8206",
          "name": "90s on 9",
          "channel_number": 9
        }
      }
    }
    """

    private let nowPlayingJSON = """
    {
      "updated_utc": "2026-07-11T02:21:42Z",
      "poll_interval_seconds": 30,
      "station_count": 3,
      "stations": {
        "8184": {
          "id": "8184",
          "name": "Faction Talk",
          "channel_number": 103,
          "artist": "TireRack.com",
          "title": "TireRack.com",
          "album": "",
          "cut_type": "Spot",
          "artwork_url": "https://stellartunerlog.com/logos/8184.png"
        },
        "8206": {
          "id": "8206",
          "name": "90s on 9",
          "channel_number": 9,
          "artist": "Bryan Adams",
          "title": "Please Forgive Me (93)",
          "album": "So Far So Good",
          "cut_type": "Song",
          "artwork_url": "https://albumart.siriusxm.com/albumart/x.jpg"
        },
        "8185": {
          "id": "8185",
          "name": "NHL Network Radio",
          "channel_number": 91,
          "artist": "The Power Play",
          "title": "Benjamin Kennedy",
          "album": "",
          "cut_type": "PGM_Segment",
          "artwork_url": "https://stellartunerlog.com/logos/8185.png"
        }
      }
    }
    """

    private let singleStationJSON = """
    {
      "updated_utc": "2026-07-11T02:21:42Z",
      "poll_interval_seconds": 30,
      "station": {
        "id": "8206",
        "name": "90s on 9",
        "channel_number": 9,
        "artist": "Bryan Adams",
        "title": "Please Forgive Me (93)",
        "album": "So Far So Good",
        "cut_type": "Song",
        "artwork_url": "https://albumart.siriusxm.com/albumart/x.jpg"
      }
    }
    """

    // MARK: - Decoding

    func testDecodeChannelList() throws {
        let response = try JSONDecoder().decode(
            STLChannelListResponse.self, from: Data(channelsJSON.utf8))
        XCTAssertEqual(response.channels.count, 2)
        let faction = try XCTUnwrap(response.channels["8184"])
        XCTAssertEqual(faction.id, "8184")
        XCTAssertEqual(faction.name, "Faction Talk")
        XCTAssertEqual(faction.channelNumber, 103)
        let nineties = try XCTUnwrap(response.channels["8206"])
        XCTAssertEqual(nineties.name, "90s on 9")
    }

    func testDecodeNowPlaying() throws {
        let response = try JSONDecoder().decode(
            STLNowPlayingResponse.self, from: Data(nowPlayingJSON.utf8))
        XCTAssertEqual(response.stations.count, 3)
        let song = try XCTUnwrap(response.stations["8206"])
        XCTAssertEqual(song.artist, "Bryan Adams")
        XCTAssertEqual(song.title, "Please Forgive Me (93)")
        XCTAssertEqual(song.cutType, "Song")
        XCTAssertEqual(song.artworkURL, "https://albumart.siriusxm.com/albumart/x.jpg")
    }

    func testDecodeSingleStation() throws {
        let response = try JSONDecoder().decode(
            STLStationResponse.self, from: Data(singleStationJSON.utf8))
        XCTAssertEqual(response.station.id, "8206")
        XCTAssertEqual(response.station.name, "90s on 9")
        XCTAssertTrue(response.station.isDisplayable)
    }

    // MARK: - Cut-type displayability (blocklist)

    private func station(
        cutType: String, artist: String = "A", title: String = "T"
    ) -> STLStation {
        STLStation(
            id: "1", name: "Ch", artist: artist, title: title, album: nil,
            cutType: cutType, artworkURL: nil)
    }

    func testFeedFixtureCutFiltering() throws {
        let response = try JSONDecoder().decode(
            STLNowPlayingResponse.self, from: Data(nowPlayingJSON.utf8))

        // Song → real track
        XCTAssertNotNil(response.stations["8206"]?.toSXMTrack(startedAt: nil))
        // Spot (ad) → no track
        XCTAssertNil(response.stations["8184"]?.toSXMTrack(startedAt: nil))
        // PGM_Segment (program segment) IS real program metadata → shown
        XCTAssertNotNil(response.stations["8185"]?.toSXMTrack(startedAt: nil))
    }

    func testProgramCutTypesAreShown() {
        // Live vocabulary is wide — anything not blocklisted is real metadata.
        XCTAssertNotNil(station(
            cutType: "Song", artist: "Bryan Adams",
            title: "Please Forgive Me (93)").toSXMTrack(startedAt: nil))
        XCTAssertNotNil(station(cutType: "Music").toSXMTrack(startedAt: nil))
        XCTAssertNotNil(station(
            cutType: "talk", artist: "The Power Play",
            title: "Benjamin Kennedy").toSXMTrack(startedAt: nil))
        XCTAssertNotNil(station(
            cutType: "sports", artist: "Rockies @ Giants",
            title: "COL 0 - SF 1 • Top 3rd").toSXMTrack(startedAt: nil))
        XCTAssertNotNil(station(cutType: "Exp").toSXMTrack(startedAt: nil))
        XCTAssertNotNil(station(cutType: "PGM_Segment").toSXMTrack(startedAt: nil))
        // The live API really ships this typo'd variant.
        XCTAssertNotNil(station(cutType: "PGM_Segement").toSXMTrack(startedAt: nil))
        // Link carries mix-show/comedy/podcast program data (e.g. SiriusXM Chill)
        XCTAssertNotNil(station(
            cutType: "Link", artist: "@Shallou",
            title: "#HouseOfChill").toSXMTrack(startedAt: nil))
    }

    func testJunkCutTypesAreHidden() {
        XCTAssertNil(station(
            cutType: "Spot", artist: "TireRack.com",
            title: "TireRack.com").toSXMTrack(startedAt: nil))
        XCTAssertNil(station(cutType: "Promo").toSXMTrack(startedAt: nil))
        XCTAssertNil(station(cutType: "Fill").toSXMTrack(startedAt: nil))
        // Perm placeholder: artist == channel name (trailing whitespace), no title
        XCTAssertNil(station(
            cutType: "Perm", artist: "Faction Talk ", title: "").toSXMTrack(startedAt: nil))
        // null/missing cut_type decodes to "" → hidden
        XCTAssertNil(station(cutType: "").toSXMTrack(startedAt: nil))
        XCTAssertNil(station(cutType: "  ").toSXMTrack(startedAt: nil))
        // Blocklist match is case-insensitive for safety
        XCTAssertNil(station(cutType: "SPOT").toSXMTrack(startedAt: nil))
        XCTAssertNil(station(cutType: "promo").toSXMTrack(startedAt: nil))
    }

    func testShownCutWithEmptyArtistAndTitleYieldsNoTrack() {
        XCTAssertNil(station(cutType: "talk", artist: "", title: "").toSXMTrack(startedAt: nil))
        XCTAssertNil(station(cutType: "Song", artist: " ", title: "").toSXMTrack(startedAt: nil))
        // One side present is still a track
        XCTAssertNotNil(station(
            cutType: "talk", artist: "", title: "Benjamin Kennedy").toSXMTrack(startedAt: nil))
    }

    // MARK: - Track mapping

    func testTrackMapping() throws {
        let response = try JSONDecoder().decode(
            STLStationResponse.self, from: Data(singleStationJSON.utf8))
        let track = try XCTUnwrap(response.station.toSXMTrack(startedAt: nil))
        // Synthesized stable id: channel|artist|title
        XCTAssertEqual(track.id, "8206|Bryan Adams|Please Forgive Me (93)")
        XCTAssertEqual(track.title, "Please Forgive Me (93)")
        XCTAssertEqual(track.artists, ["Bryan Adams"])
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://albumart.siriusxm.com/albumart/x.jpg")
    }

    // MARK: - First-observation startedAt synthesis

    func testStartedAtStampedOnFirstObservationAndReusedAfter() throws {
        let station = STLStation(
            id: "8206", name: "90s on 9", artist: "Bryan Adams",
            title: "Please Forgive Me (93)", album: nil,
            cutType: "Song", artworkURL: nil)

        let firstSeen = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_030)

        // First observation: no history entry → stamped with "now"
        let first = try XCTUnwrap(
            SXMMetadataService.stlTrack(from: station, history: [], now: firstSeen))
        XCTAssertEqual(first.startedAt, firstSeen)

        // Re-observation 30s later: same track id in history → startedAt reused
        let second = SXMMetadataService.stlTrack(from: station, history: [first], now: later)
        XCTAssertEqual(second?.startedAt, firstSeen)
        XCTAssertEqual(second?.id, first.id)

        // Different song on the same channel → fresh startedAt
        let nextSong = STLStation(
            id: "8206", name: "90s on 9", artist: "Oasis",
            title: "Wonderwall", album: nil, cutType: "Song", artworkURL: nil)
        let third = SXMMetadataService.stlTrack(from: nextSong, history: [first], now: later)
        XCTAssertEqual(third?.startedAt, later)
        XCTAssertNotEqual(third?.id, first.id)
    }

    // MARK: - Degenerate / malformed entries

    func testDegenerateStationSurvivesAndMalformedEntryDrops() throws {
        // "8206": missing `artist` → decodes with empty artist, still a Song.
        // "8184": null `cut_type` → decodes with empty cutType → no track.
        // "9999": missing required `id` → entry drops, response survives.
        let json = """
        {
          "stations": {
            "8206": {
              "id": "8206",
              "name": "90s on 9",
              "title": "Please Forgive Me (93)",
              "cut_type": "Song"
            },
            "8184": {
              "id": "8184",
              "name": "Faction Talk",
              "artist": "Somebody",
              "title": "Something",
              "cut_type": null
            },
            "9999": {
              "name": "No ID Here"
            }
          }
        }
        """
        let response = try JSONDecoder().decode(
            STLNowPlayingResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.stations.count, 2)
        XCTAssertNil(response.stations["9999"], "malformed entry should drop")

        let noArtist = try XCTUnwrap(response.stations["8206"])
        XCTAssertEqual(noArtist.artist, "")
        XCTAssertNotNil(noArtist.toSXMTrack(startedAt: nil), "Song cut still yields a track")

        let noCutType = try XCTUnwrap(response.stations["8184"])
        XCTAssertEqual(noCutType.cutType, "")
        XCTAssertNil(noCutType.toSXMTrack(startedAt: nil), "empty cutType degrades to no track")
    }

    func testMalformedChannelEntryDropsFromChannelList() throws {
        let json = """
        {
          "channels": {
            "8206": {"id": "8206", "name": "90s on 9", "channel_number": 9},
            "bad": {"name": "Missing ID"},
            "worse": "not even an object"
          }
        }
        """
        let response = try JSONDecoder().decode(
            STLChannelListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.channels.count, 1)
        XCTAssertEqual(response.channels["8206"]?.name, "90s on 9")
    }

    // MARK: - Channel matching

    func testBuildDeeplinkMapMatchesBothIdentifierShapes() {
        func channel(_ id: String, _ name: String) -> Channel {
            Channel(id: id, name: name, streamURL: URL(string: "http://example.com/\(id)")!, group: "SiriusXM")
        }
        let channels = [
            channel("c1", "Radio: 90s on 9"),        // exact after prefix strip
            channel("c2", "The Coffee House Ch 14"), // word-boundary contains
            channel("c3", "Totally Unrelated"),      // no match
        ]

        // xmplaylist shape: identifier is a deeplink slug
        let xmStations: [SXMMetadataService.MatchableStation] = [
            (name: "90s on 9", identifier: "90s-on-9"),
            (name: "The Coffee House", identifier: "the-coffee-house"),
        ]
        let xmMap = SXMMetadataService.buildDeeplinkMap(
            appChannels: channels, stations: xmStations, sortPrefixes: ["Radio: "])
        XCTAssertEqual(xmMap["c1"], "90s-on-9", "exact match")
        XCTAssertEqual(xmMap["c2"], "the-coffee-house", "word-boundary match")
        XCTAssertNil(xmMap["c3"])

        // stellartunerlog shape: identifier is a numeric channel id
        let stlStations: [SXMMetadataService.MatchableStation] = [
            (name: "90s on 9", identifier: "8206"),
            (name: "The Coffee House", identifier: "8210"),
        ]
        let stlMap = SXMMetadataService.buildDeeplinkMap(
            appChannels: channels, stations: stlStations, sortPrefixes: ["Radio: "])
        XCTAssertEqual(stlMap["c1"], "8206", "exact match")
        XCTAssertEqual(stlMap["c2"], "8210", "word-boundary match")
        XCTAssertNil(stlMap["c3"])
    }

    // MARK: - Source enum

    func testMetadataSourceDefaultsToXMPlaylist() {
        let key = SXMMetadataSource.defaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(SXMMetadataSource.current, .xmplaylist)

        UserDefaults.standard.set("stellartunerlog", forKey: key)
        XCTAssertEqual(SXMMetadataSource.current, .stellartunerlog)

        // Unknown value falls back to the default
        UserDefaults.standard.set("garbage", forKey: key)
        XCTAssertEqual(SXMMetadataSource.current, .xmplaylist)
    }
}
