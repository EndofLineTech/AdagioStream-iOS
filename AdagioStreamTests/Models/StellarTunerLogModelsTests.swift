import XCTest
@testable import AdagioStream

/// Tests for the StellarTunerLog (api.stellartunerlog.com/v1) response models,
/// the Song/Music cut-type filter, and the first-observation startedAt/id
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
        XCTAssertTrue(response.station.isMusic)
    }

    // MARK: - Cut-type filter

    func testOnlySongAndMusicCutsAreTracks() throws {
        let response = try JSONDecoder().decode(
            STLNowPlayingResponse.self, from: Data(nowPlayingJSON.utf8))

        // Song → real track
        XCTAssertNotNil(response.stations["8206"]?.toSXMTrack(startedAt: nil))
        // Spot (ad) → no track
        XCTAssertNil(response.stations["8184"]?.toSXMTrack(startedAt: nil))
        // PGM_Segment (program segment) → no track
        XCTAssertNil(response.stations["8185"]?.toSXMTrack(startedAt: nil))

        // "Music" cut type is also a real track
        let music = STLStation(
            id: "1", name: "Ch", artist: "A", title: "T", album: nil,
            cutType: "Music", artworkURL: nil)
        XCTAssertTrue(music.isMusic)
        XCTAssertNotNil(music.toSXMTrack(startedAt: nil))
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
