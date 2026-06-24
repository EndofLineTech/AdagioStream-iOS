import XCTest
import GRDB
@testable import AdagioStream

/// Tests for the Navidrome domain models (Artist, Album, Track, Genre) and
/// their Subsonic DTO mappings.  All persistence tests use an in-memory
/// `NavidromeStore` (DatabaseQueue) so no disk I/O is required.
final class NavidromeModelsTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> NavidromeStore {
        try NavidromeStore(writer: try DatabaseQueue())
    }

    /// A fixed "now" timestamp used across tests so assertions are deterministic.
    private let now: Int = 1_700_000_000

    // MARK: - Round-trip: Artist

    func testArtistRoundTrip() throws {
        let store = try makeStore()
        let original = Artist(
            id: "art-1",
            name: "Radiohead",
            sortName: "Radiohead",
            albumCount: 9,
            coverArt: "ca-art-1",
            updatedAt: now
        )
        try store.upsert(artists: [original])

        let fetched = try store.writer.read { db in
            try Artist.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        let a = try XCTUnwrap(fetched.first)
        XCTAssertEqual(a.id,         "art-1")
        XCTAssertEqual(a.name,       "Radiohead")
        XCTAssertEqual(a.sortName,   "Radiohead")
        XCTAssertEqual(a.albumCount, 9)
        XCTAssertEqual(a.coverArt,   "ca-art-1")
        XCTAssertEqual(a.updatedAt,  now)
    }

    // MARK: - Round-trip: Album

    func testAlbumRoundTrip() throws {
        let store = try makeStore()
        let artist = Artist(id: "art-1", name: "Radiohead", updatedAt: now)
        try store.upsert(artists: [artist])

        let original = Album(
            id: "alb-1",
            artistId: "art-1",
            title: "OK Computer",
            sortTitle: "OK Computer",
            year: 1997,
            genre: "Art Rock",
            trackCount: 12,
            coverArt: "ca-alb-1",
            updatedAt: now
        )
        try store.upsert(albums: [original])

        let fetched = try store.writer.read { db in
            try Album.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        let alb = try XCTUnwrap(fetched.first)
        XCTAssertEqual(alb.id,         "alb-1")
        XCTAssertEqual(alb.artistId,   "art-1")
        XCTAssertEqual(alb.title,      "OK Computer")
        XCTAssertEqual(alb.sortTitle,  "OK Computer")
        XCTAssertEqual(alb.year,       1997)
        XCTAssertEqual(alb.genre,      "Art Rock")
        XCTAssertEqual(alb.trackCount, 12)
        XCTAssertEqual(alb.coverArt,   "ca-alb-1")
        XCTAssertEqual(alb.updatedAt,  now)
    }

    // MARK: - Round-trip: Track

    func testTrackRoundTrip() throws {
        let store = try makeStore()
        try store.upsert(artists: [Artist(id: "art-1", name: "Radiohead", updatedAt: now)])
        try store.upsert(albums: [Album(id: "alb-1", artistId: "art-1", title: "OK Computer", updatedAt: now)])

        let original = Track(
            id: "trk-1",
            albumId: "alb-1",
            artistId: "art-1",
            title: "Paranoid Android",
            trackNumber: 2,
            discNumber: 1,
            duration: 383,
            genre: "Art Rock",
            bitRate: 320,
            suffix: "mp3",
            contentType: "audio/mpeg",
            coverArt: "ca-trk-1",
            path: "/music/ok-computer/02-paranoid-android.mp3",
            updatedAt: now
        )
        try store.upsert(tracks: [original])

        let fetched = try store.writer.read { db in
            try Track.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        let trk = try XCTUnwrap(fetched.first)
        XCTAssertEqual(trk.id,          "trk-1")
        XCTAssertEqual(trk.albumId,     "alb-1")
        XCTAssertEqual(trk.artistId,    "art-1")
        XCTAssertEqual(trk.title,       "Paranoid Android")
        XCTAssertEqual(trk.trackNumber, 2)
        XCTAssertEqual(trk.discNumber,  1)
        XCTAssertEqual(trk.duration,    383)
        XCTAssertEqual(trk.genre,       "Art Rock")
        XCTAssertEqual(trk.bitRate,     320)
        XCTAssertEqual(trk.suffix,      "mp3")
        XCTAssertEqual(trk.contentType, "audio/mpeg")
        XCTAssertEqual(trk.coverArt,    "ca-trk-1")
        XCTAssertEqual(trk.path,        "/music/ok-computer/02-paranoid-android.mp3")
        XCTAssertEqual(trk.updatedAt,   now)
    }

    // MARK: - Fetch helpers

    func testAlbumsForArtist() throws {
        let store = try makeStore()
        try store.upsert(artists: [
            Artist(id: "art-1", name: "Radiohead", updatedAt: now),
            Artist(id: "art-2", name: "Portishead", updatedAt: now),
        ])
        try store.upsert(albums: [
            Album(id: "alb-1", artistId: "art-1", title: "OK Computer", year: 1997, updatedAt: now),
            Album(id: "alb-2", artistId: "art-1", title: "Kid A",       year: 2000, updatedAt: now),
            Album(id: "alb-3", artistId: "art-2", title: "Dummy",       year: 1994, updatedAt: now),
        ])

        let radioheadAlbums = try store.albums(forArtist: "art-1")
        XCTAssertEqual(radioheadAlbums.count, 2)
        // Ordered by year ascending.
        XCTAssertEqual(radioheadAlbums[0].id, "alb-1")
        XCTAssertEqual(radioheadAlbums[1].id, "alb-2")

        let portisheadAlbums = try store.albums(forArtist: "art-2")
        XCTAssertEqual(portisheadAlbums.count, 1)
        XCTAssertEqual(portisheadAlbums[0].id, "alb-3")
    }

    func testTracksForAlbum() throws {
        let store = try makeStore()
        try store.upsert(artists: [Artist(id: "art-1", name: "Radiohead", updatedAt: now)])
        try store.upsert(albums: [
            Album(id: "alb-1", artistId: "art-1", title: "OK Computer", updatedAt: now),
            Album(id: "alb-2", artistId: "art-1", title: "Kid A",       updatedAt: now),
        ])
        try store.upsert(tracks: [
            Track(id: "trk-1", albumId: "alb-1", artistId: "art-1", title: "Airbag",           trackNumber: 1, updatedAt: now),
            Track(id: "trk-2", albumId: "alb-1", artistId: "art-1", title: "Paranoid Android", trackNumber: 2, updatedAt: now),
            Track(id: "trk-3", albumId: "alb-2", artistId: "art-1", title: "Everything in Its Right Place", trackNumber: 1, updatedAt: now),
        ])

        let okTracks = try store.tracks(forAlbum: "alb-1")
        XCTAssertEqual(okTracks.count, 2)
        // Ordered by discNumber, trackNumber.
        XCTAssertEqual(okTracks[0].id, "trk-1")
        XCTAssertEqual(okTracks[1].id, "trk-2")

        let kidATracks = try store.tracks(forAlbum: "alb-2")
        XCTAssertEqual(kidATracks.count, 1)
        XCTAssertEqual(kidATracks[0].id, "trk-3")
    }

    // MARK: - ON DELETE CASCADE

    func testDeleteArtistCascadesToAlbumsAndTracks() throws {
        let store = try makeStore()
        try store.upsert(artists: [Artist(id: "art-1", name: "Radiohead", updatedAt: now)])
        try store.upsert(albums:  [Album(id: "alb-1", artistId: "art-1", title: "OK Computer", updatedAt: now)])
        try store.upsert(tracks:  [
            Track(id: "trk-1", albumId: "alb-1", artistId: "art-1", title: "Airbag", updatedAt: now),
            Track(id: "trk-2", albumId: "alb-1", artistId: "art-1", title: "Paranoid Android", updatedAt: now),
        ])

        // Verify data was inserted.
        let preAlbums = try store.albums(forArtist: "art-1")
        XCTAssertEqual(preAlbums.count, 1)
        let preTracks = try store.tracks(forAlbum: "alb-1")
        XCTAssertEqual(preTracks.count, 2)

        // Delete the artist.
        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM artists WHERE id = ?", arguments: ["art-1"])
        }

        // Albums and tracks must be gone due to ON DELETE CASCADE.
        let postAlbums = try store.writer.read { db in try Album.fetchAll(db) }
        XCTAssertEqual(postAlbums.count, 0, "Albums should be deleted via cascade")

        let postTracks = try store.writer.read { db in try Track.fetchAll(db) }
        XCTAssertEqual(postTracks.count, 0, "Tracks should be deleted via cascade")
    }

    // MARK: - Subsonic JSON decoding: Artist

    func testSubsonicArtistDTODecoding() throws {
        let json = """
        {
            "id": "art-42",
            "name": "Massive Attack",
            "albumCount": 5,
            "coverArt": "ar-42",
            "artistImageUrl": "https://example.com/img.jpg"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicArtistDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id,         "art-42")
        XCTAssertEqual(dto.name,       "Massive Attack")
        XCTAssertEqual(dto.albumCount, 5)
        XCTAssertEqual(dto.coverArt,   "ar-42")

        let record = dto.toRecord(updatedAt: now)
        XCTAssertEqual(record.id,         "art-42")
        XCTAssertEqual(record.name,       "Massive Attack")
        XCTAssertEqual(record.albumCount, 5)
        XCTAssertEqual(record.coverArt,   "ar-42")
        XCTAssertEqual(record.updatedAt,  now)
        // artistImageUrl is intentionally not stored.
        XCTAssertNil(record.sortName)
    }

    // MARK: - Subsonic JSON decoding: Album (name vs title duality)

    func testSubsonicAlbumDTODecodingWithNameField() throws {
        // getArtist / getAlbumList2 shape — title arrives as "name".
        let json = """
        {
            "id": "alb-100",
            "artistId": "art-42",
            "name": "Blue Lines",
            "year": 1991,
            "genre": "Trip Hop",
            "songCount": 9,
            "coverArt": "ca-100"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.resolvedTitle, "Blue Lines",
                       "resolvedTitle should fall back to 'name' when 'title' is absent")

        let record = dto.toRecord(updatedAt: now)
        XCTAssertEqual(record.title,      "Blue Lines")
        XCTAssertEqual(record.trackCount, 9)
        XCTAssertEqual(record.year,       1991)
        XCTAssertEqual(record.genre,      "Trip Hop")
    }

    func testSubsonicAlbumDTODecodingWithTitleField() throws {
        // getAlbum detail shape — title arrives as "title".
        let json = """
        {
            "id": "alb-101",
            "artistId": "art-42",
            "title": "Mezzanine",
            "year": 1998,
            "genre": "Trip Hop",
            "songCount": 11,
            "coverArt": "ca-101"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.resolvedTitle, "Mezzanine",
                       "resolvedTitle should prefer 'title' when present")

        let record = dto.toRecord(updatedAt: now)
        XCTAssertEqual(record.title,      "Mezzanine")
        XCTAssertEqual(record.trackCount, 11)
    }

    func testSubsonicAlbumDTOTitleWinsOverName() throws {
        // Edge case: both "name" and "title" present — "title" must win.
        let json = """
        {
            "id": "alb-102",
            "artistId": "art-42",
            "name": "NameField",
            "title": "TitleField",
            "songCount": 0
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.resolvedTitle, "TitleField",
                       "'title' must take precedence over 'name'")
    }

    // MARK: - Subsonic JSON decoding: Track (track-number mismatch)

    func testSubsonicTrackDTODecoding() throws {
        let json = """
        {
            "id": "trk-500",
            "albumId": "alb-100",
            "artistId": "art-42",
            "title": "Safe from Harm",
            "track": 1,
            "discNumber": 1,
            "duration": 336,
            "year": 1991,
            "genre": "Trip Hop",
            "coverArt": "ca-500",
            "bitRate": 320,
            "suffix": "flac",
            "contentType": "audio/flac",
            "path": "/music/blue-lines/01-safe-from-harm.flac"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicTrackDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id,       "trk-500")
        XCTAssertEqual(dto.title,    "Safe from Harm")

        let record = dto.toRecord(updatedAt: now)
        XCTAssertEqual(record.trackNumber, 1,
                       "Subsonic 'track' field must map to trackNumber")
        XCTAssertEqual(record.discNumber,  1)
        XCTAssertEqual(record.duration,    336)
        XCTAssertEqual(record.bitRate,     320)
        XCTAssertEqual(record.suffix,      "flac")
        XCTAssertEqual(record.contentType, "audio/flac")
        XCTAssertEqual(record.path, "/music/blue-lines/01-safe-from-harm.flac")
        XCTAssertEqual(record.updatedAt,   now)
    }

    // MARK: - 65x.3: playCount parsing (SubsonicAlbumDTO)

    func testAlbumDTOPlayCountPresent() throws {
        let json = """
        {
            "id": "alb-200",
            "artistId": "art-1",
            "name": "Play Often",
            "playCount": 42
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.playCount, 42,
                       "playCount should be decoded when present in the album JSON")
    }

    func testAlbumDTOPlayCountAbsent() throws {
        let json = """
        {
            "id": "alb-201",
            "artistId": "art-1",
            "name": "No Plays"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.playCount,
                     "playCount should be nil when absent from the album JSON")
    }

    func testAlbumDTOPlayCountZero() throws {
        let json = """
        {
            "id": "alb-202",
            "artistId": "art-1",
            "name": "Never Played",
            "playCount": 0
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.playCount, 0,
                       "playCount of 0 should decode as 0, not nil")
    }

    // MARK: - 65x.3: playCount parsing (SubsonicTrackDTO)

    func testTrackDTOPlayCountPresent() throws {
        let json = """
        {
            "id": "trk-600",
            "albumId": "alb-100",
            "artistId": "art-1",
            "title": "Frequent Track",
            "playCount": 99
        }
        """
        let dto = try JSONDecoder().decode(SubsonicTrackDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.playCount, 99,
                       "playCount should be decoded when present in the track JSON")
    }

    func testTrackDTOPlayCountAbsent() throws {
        let json = """
        {
            "id": "trk-601",
            "albumId": "alb-100",
            "artistId": "art-1",
            "title": "Unplayed Track"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicTrackDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.playCount,
                     "playCount should be nil when absent from the track JSON")
    }

    // MARK: - 65x.3: starred state still derives correctly

    func testAlbumDTOStarredPresent() throws {
        let json = """
        {
            "id": "alb-300",
            "artistId": "art-1",
            "name": "Starred Album",
            "starred": "2024-01-15T12:00:00"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertTrue(dto.starred,
                      "starred should be true when the 'starred' date-string field is present")
    }

    func testAlbumDTOStarredAbsent() throws {
        let json = """
        {
            "id": "alb-301",
            "artistId": "art-1",
            "name": "Unstarred Album"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicAlbumDTO.self, from: Data(json.utf8))
        XCTAssertFalse(dto.starred,
                       "starred should be false when the 'starred' field is absent")
    }

    func testTrackDTOStarredPresent() throws {
        let json = """
        {
            "id": "trk-700",
            "albumId": "alb-1",
            "artistId": "art-1",
            "title": "Starred Track",
            "starred": "2025-03-01T09:00:00"
        }
        """
        let dto = try JSONDecoder().decode(SubsonicTrackDTO.self, from: Data(json.utf8))
        XCTAssertTrue(dto.starred,
                      "starred should be true when 'starred' date-string is present on a track")
    }

    // MARK: - 65x.3: navidromePlayCountText helper

    func testPlayCountTextNil() {
        XCTAssertNil(navidromePlayCountText(nil),
                     "navidromePlayCountText should return nil for nil input")
    }

    func testPlayCountTextZero() {
        XCTAssertNil(navidromePlayCountText(0),
                     "navidromePlayCountText should return nil for zero plays")
    }

    func testPlayCountTextPositive() {
        XCTAssertEqual(navidromePlayCountText(1),  "▶ 1")
        XCTAssertEqual(navidromePlayCountText(42), "▶ 42")
        XCTAssertEqual(navidromePlayCountText(999), "▶ 999")
    }

    // MARK: - Subsonic JSON decoding: Genre

    func testGenreDTODecoding() throws {
        let json = """
        [
            { "value": "Trip Hop", "songCount": 42, "albumCount": 3 },
            { "value": "Art Rock", "songCount": 118, "albumCount": 9 }
        ]
        """
        let genres = try JSONDecoder().decode([Genre].self, from: Data(json.utf8))
        XCTAssertEqual(genres.count, 2)

        let tripHop = try XCTUnwrap(genres.first(where: { $0.name == "Trip Hop" }))
        XCTAssertEqual(tripHop.songCount,  42)
        XCTAssertEqual(tripHop.albumCount, 3)

        let artRock = try XCTUnwrap(genres.first(where: { $0.name == "Art Rock" }))
        XCTAssertEqual(artRock.songCount,  118)
        XCTAssertEqual(artRock.albumCount, 9)
    }
}
