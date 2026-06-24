// MARK: - Navidrome / Subsonic Domain Models
//
// Mapping approach: DTO layer.
//
// The GRDB record types (Artist, Album, Track) use property names that exactly
// match the v1 schema column names so that the default Codable-based
// FetchableRecord / PersistableRecord implementations work without any custom
// CodingKeys on the record side.
//
// Subsonic JSON field names differ from the schema columns in several places:
//   • album.name  (getArtist/getAlbumList2) vs. album.title  (getAlbum detail)
//   • song.track  → trackNumber
//   • album.songCount → trackCount
//   • artist/album.artistImageUrl  — not stored (no column in v1)
//
// Rather than burdening the record types with conditional CodingKeys or
// computed properties, three lightweight DTO structs own the Subsonic-specific
// decoding and expose a `toRecord(updatedAt:)` method that creates the
// corresponding GRDB record.  This keeps each layer focused on a single
// responsibility and makes it easy to handle the name/title duality cleanly.
//
// `updatedAt` is a local sync timestamp (Unix epoch seconds). It is always set
// at insert time — never sourced from the Subsonic server — so it is a
// parameter on every `toRecord(updatedAt:)` call rather than decoded from JSON.

import Foundation
import GRDB

// MARK: - GRDB Record Types

/// A music artist persisted to the `artists` table (v1 schema).
public struct Artist: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artists"

    public var id: String
    public var name: String
    public var sortName: String?
    public var albumCount: Int
    public var coverArt: String?
    public var updatedAt: Int

    public init(
        id: String,
        name: String,
        sortName: String? = nil,
        albumCount: Int = 0,
        coverArt: String? = nil,
        updatedAt: Int
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.albumCount = albumCount
        self.coverArt = coverArt
        self.updatedAt = updatedAt
    }
}

/// A music album persisted to the `albums` table (v1 schema).
public struct Album: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "albums"

    public var id: String
    public var artistId: String
    public var title: String
    public var sortTitle: String?
    public var year: Int?
    public var genre: String?
    public var trackCount: Int
    public var coverArt: String?
    public var updatedAt: Int

    public init(
        id: String,
        artistId: String,
        title: String,
        sortTitle: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        trackCount: Int = 0,
        coverArt: String? = nil,
        updatedAt: Int
    ) {
        self.id = id
        self.artistId = artistId
        self.title = title
        self.sortTitle = sortTitle
        self.year = year
        self.genre = genre
        self.trackCount = trackCount
        self.coverArt = coverArt
        self.updatedAt = updatedAt
    }
}

/// A music track persisted to the `tracks` table (v1 schema).
public struct Track: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tracks"

    public var id: String
    public var albumId: String
    public var artistId: String
    public var title: String
    public var trackNumber: Int?
    public var discNumber: Int
    public var duration: Int?
    public var genre: String?
    public var bitRate: Int?
    public var suffix: String?
    public var contentType: String?
    public var coverArt: String?
    public var path: String?
    public var updatedAt: Int

    public init(
        id: String,
        albumId: String,
        artistId: String,
        title: String,
        trackNumber: Int? = nil,
        discNumber: Int = 1,
        duration: Int? = nil,
        genre: String? = nil,
        bitRate: Int? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        coverArt: String? = nil,
        path: String? = nil,
        updatedAt: Int
    ) {
        self.id = id
        self.albumId = albumId
        self.artistId = artistId
        self.title = title
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.genre = genre
        self.bitRate = bitRate
        self.suffix = suffix
        self.contentType = contentType
        self.coverArt = coverArt
        self.path = path
        self.updatedAt = updatedAt
    }
}

// MARK: - Genre (lightweight, no GRDB table in v1)

/// A music genre decoded from the Subsonic `getGenres` response.
///
/// The v1 schema stores genre as a plain `TEXT` column on albums and tracks;
/// there is no standalone `genres` table.  This struct is used when consuming
/// the `getGenres` endpoint only.
public struct Genre: Codable, Hashable {
    /// The genre name — Subsonic field: `value`.
    public var name: String
    /// Number of tracks with this genre.
    public var songCount: Int
    /// Number of albums with this genre.
    public var albumCount: Int

    public init(name: String, songCount: Int, albumCount: Int) {
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
    }

    enum CodingKeys: String, CodingKey {
        case name = "value"
        case songCount
        case albumCount
    }
}

// MARK: - Playlist (live-fetched, no GRDB table in v1)

/// A Subsonic/Navidrome playlist decoded from `getPlaylists` or `getPlaylist`.
///
/// Playlists are fetched live from the server and are not cached in the v1
/// local database.  This struct is a plain value type — it does NOT conform to
/// `FetchableRecord` or `PersistableRecord`.
///
/// Field names match the Subsonic JSON keys exactly, so no custom `CodingKeys`
/// are required.
public struct Playlist: Codable, Hashable {
    /// Subsonic playlist ID.
    public var id: String
    /// Playlist display name.
    public var name: String
    /// Number of tracks in the playlist.
    public var songCount: Int
    /// Total duration in seconds.
    public var duration: Int
    /// Username of the playlist owner.
    public var owner: String?
    /// Whether the playlist is publicly visible.
    public var `public`: Bool?
    /// Optional free-text comment.
    public var comment: String?
    /// Cover art ID — pass to `NavidromeAPI.coverArtURL(id:)`.
    public var coverArt: String?
    /// ISO-8601 creation timestamp string as returned by the server.
    public var created: String?
    /// ISO-8601 last-modified timestamp string as returned by the server.
    public var changed: String?

    public init(
        id: String,
        name: String,
        songCount: Int,
        duration: Int,
        owner: String? = nil,
        public: Bool? = nil,
        comment: String? = nil,
        coverArt: String? = nil,
        created: String? = nil,
        changed: String? = nil
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.duration = duration
        self.owner = owner
        self.`public` = `public`
        self.comment = comment
        self.coverArt = coverArt
        self.created = created
        self.changed = changed
    }
}

// MARK: - Subsonic DTO Layer

// MARK: - Transient star / rating overlay (65x.2)
//
// `starred` and `userRating` are NOT persisted to the GRDB v1 schema — there
// are no columns for them in the `artists`, `albums`, or `tracks` tables.
// They are carried in-memory on the DTO layer only (SubsonicArtistDTO,
// SubsonicAlbumDTO, SubsonicTrackDTO) and derived from the live server response.
//
// The GRDB record types (Artist, Album, Track) remain unchanged; adding
// transient properties to those types would require excluding them from the
// synthesised Codable CodingKeys or the GRDB row would fail to decode.
// Keeping them on the DTOs is the cleanest separation.
//
// `starred` is derived from the Subsonic `starred` field: the server emits a
// date-string value (e.g. "2024-01-15T12:00:00") when the item is starred and
// omits the key entirely when it is not.  We map presence → `true`, absence → `false`.
//
// FAVORITES SEPARATION:
// Navidrome `starred` is server-side and applies to music library items
// (tracks, albums, artists). The app's ProviderManager `favoriteOrder` /
// `toggleFavorite` system is LOCAL and applies only to radio channels (live
// streams). These domains are kept strictly separate — do NOT route Navidrome
// stars through the channel favorites pipeline.

/// Decodes a single artist entry from Subsonic `getArtists` / `getIndexes`.
///
/// Subsonic fields: `id`, `name`, `albumCount`, `coverArt`, `artistImageUrl`
/// (artistImageUrl is intentionally discarded — no v1 column).
///
/// `starred` is a transient field — not stored in GRDB — derived from whether
/// the Subsonic `starred` date-string field is present in the response.
public struct SubsonicArtistDTO: Decodable {
    public let id: String
    public let name: String
    public let albumCount: Int?
    public let coverArt: String?
    /// True when the Subsonic `starred` field is present (non-null) in the response.
    /// This is a transient/display field — not persisted to the GRDB `artists` table.
    public let starred: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, albumCount, coverArt
        case starredField = "starred"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        albumCount = try? c.decodeIfPresent(Int.self, forKey: .albumCount)
        coverArt   = try? c.decodeIfPresent(String.self, forKey: .coverArt)
        // starred: present (any non-null value) → true; absent → false
        let starredValue = try? c.decodeIfPresent(String.self, forKey: .starredField)
        starred = starredValue != nil
    }

    public func toRecord(updatedAt: Int) -> Artist {
        Artist(
            id: id,
            name: name,
            sortName: nil,
            albumCount: albumCount ?? 0,
            coverArt: coverArt,
            updatedAt: updatedAt
        )
    }
}

/// Decodes a single album entry from Subsonic `getArtist`, `getAlbumList2`,
/// or `getAlbum`.
///
/// Subsonic fields vary by endpoint:
///   • `getArtist` / `getAlbumList2`: uses `"name"` for the album title
///   • `getAlbum` detail: uses `"title"` for the album title
/// Both are decoded; `title` wins when present; `name` is the fallback.
///
/// `songCount` → `trackCount`.
/// `artist` (display name string) is captured in `artistName` for UI display
/// (e.g. album-detail header and now-playing subtitle); `artistId` is the
/// foreign key used for DB relations.
///
/// `starred` and `userRating` are transient display fields — not persisted to
/// the GRDB `albums` table (no v1 columns exist for them).
public struct SubsonicAlbumDTO: Decodable {
    public let id: String
    public let artistId: String
    /// Human-readable artist display name from the `"artist"` Subsonic field.
    /// Present in both `getArtist`/`getAlbumList2` and `getAlbum` responses.
    /// Used to show the real artist name in the browse UI and now-playing
    /// subtitle instead of the raw `artistId` foreign key.
    public let artistName: String?
    /// Album title. In `getArtist`/`getAlbumList2` responses this arrives as
    /// `"name"`. In `getAlbum` detail it arrives as `"title"`. Both are decoded
    /// and `resolvedTitle` picks the right one.
    let nameField: String?
    let titleField: String?
    public let year: Int?
    public let genre: String?
    public let songCount: Int?
    public let coverArt: String?
    /// True when the Subsonic `starred` date-string field is present in the response.
    /// Transient — not persisted to the GRDB `albums` table.
    public let starred: Bool
    /// User-assigned 0–5 star rating from the Subsonic `userRating` field.
    /// Transient — not persisted to the GRDB `albums` table.
    public let userRating: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case artistId
        case artistName = "artist"
        case nameField  = "name"
        case titleField = "title"
        case year
        case genre
        case songCount
        case coverArt
        case starredField  = "starred"
        case userRating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        artistId   = try c.decode(String.self, forKey: .artistId)
        artistName = try? c.decodeIfPresent(String.self, forKey: .artistName)
        nameField  = try? c.decodeIfPresent(String.self, forKey: .nameField)
        titleField = try? c.decodeIfPresent(String.self, forKey: .titleField)
        year       = try? c.decodeIfPresent(Int.self,    forKey: .year)
        genre      = try? c.decodeIfPresent(String.self, forKey: .genre)
        songCount  = try? c.decodeIfPresent(Int.self,    forKey: .songCount)
        coverArt   = try? c.decodeIfPresent(String.self, forKey: .coverArt)
        userRating = try? c.decodeIfPresent(Int.self,    forKey: .userRating)
        // starred: present (any non-null string) → true; absent → false
        let starredValue = try? c.decodeIfPresent(String.self, forKey: .starredField)
        starred = starredValue != nil
    }

    /// The resolved album title: `title` field wins over `name` field.
    public var resolvedTitle: String {
        titleField ?? nameField ?? ""
    }

    public func toRecord(updatedAt: Int) -> Album {
        Album(
            id: id,
            artistId: artistId,
            title: resolvedTitle,
            sortTitle: nil,
            year: year,
            genre: genre,
            trackCount: songCount ?? 0,
            coverArt: coverArt,
            updatedAt: updatedAt
        )
    }
}

/// Decodes a single song/track entry from Subsonic `getAlbum` / `getSong`.
///
/// Key mismatches handled:
///   • `track` → `trackNumber`
///   • `duration` is passed through as-is (seconds, Int)
///   • `artist` (name string) is discarded — `artistId` is used
///   • `album` (name string) is discarded — `albumId` is used
///
/// `starred` and `userRating` are transient display fields — not persisted to
/// the GRDB `tracks` table (no v1 columns exist for them).
public struct SubsonicTrackDTO: Decodable {
    public let id: String
    public let albumId: String
    public let artistId: String
    public let title: String
    let trackField: Int?
    public let discNumber: Int?
    public let duration: Int?
    public let year: Int?
    public let genre: String?
    public let coverArt: String?
    public let bitRate: Int?
    public let suffix: String?
    public let contentType: String?
    public let path: String?
    /// True when the Subsonic `starred` date-string field is present in the response.
    /// Transient — not persisted to the GRDB `tracks` table.
    public let starred: Bool
    /// User-assigned 0–5 star rating from the Subsonic `userRating` field.
    /// Transient — not persisted to the GRDB `tracks` table.
    public let userRating: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case albumId
        case artistId
        case title
        case trackField  = "track"
        case discNumber
        case duration
        case year
        case genre
        case coverArt
        case bitRate
        case suffix
        case contentType
        case path
        case starredField = "starred"
        case userRating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        albumId     = try c.decode(String.self, forKey: .albumId)
        artistId    = try c.decode(String.self, forKey: .artistId)
        title       = try c.decode(String.self, forKey: .title)
        trackField  = try? c.decodeIfPresent(Int.self,    forKey: .trackField)
        discNumber  = try? c.decodeIfPresent(Int.self,    forKey: .discNumber)
        duration    = try? c.decodeIfPresent(Int.self,    forKey: .duration)
        year        = try? c.decodeIfPresent(Int.self,    forKey: .year)
        genre       = try? c.decodeIfPresent(String.self, forKey: .genre)
        coverArt    = try? c.decodeIfPresent(String.self, forKey: .coverArt)
        bitRate     = try? c.decodeIfPresent(Int.self,    forKey: .bitRate)
        suffix      = try? c.decodeIfPresent(String.self, forKey: .suffix)
        contentType = try? c.decodeIfPresent(String.self, forKey: .contentType)
        path        = try? c.decodeIfPresent(String.self, forKey: .path)
        userRating  = try? c.decodeIfPresent(Int.self,    forKey: .userRating)
        // starred: present (any non-null string) → true; absent → false
        let starredValue = try? c.decodeIfPresent(String.self, forKey: .starredField)
        starred = starredValue != nil
    }

    public func toRecord(updatedAt: Int) -> Track {
        Track(
            id: id,
            albumId: albumId,
            artistId: artistId,
            title: title,
            trackNumber: trackField,
            discNumber: discNumber ?? 1,
            duration: duration,
            genre: genre,
            bitRate: bitRate,
            suffix: suffix,
            contentType: contentType,
            coverArt: coverArt,
            path: path,
            updatedAt: updatedAt
        )
    }
}
