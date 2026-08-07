import Foundation

extension NavidromeAPI {
    // MARK: - Library browse endpoints

    /// Fetches all artists from `getArtists.view`, flattening the alphabetical
    /// index buckets into a single `[Artist]`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"artists":{"index":[{"name":"A","artist":[…]}]}}
    /// ```
    public func getArtists() async throws -> [Artist] {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getArtists", params: [:], as: GetArtistsPayload.self)
        return payload.artists.index.flatMap { bucket in
            bucket.artist.map { $0.toRecord(updatedAt: now) }
        }
    }

    /// Fetches a single artist and their albums from `getArtist.view?id=`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"artist":{"id":…,"name":…,"album":[…]}}
    /// ```
    /// - Returns: The `Artist` record and all of its `[Album]` records.
    public func getArtist(id: String) async throws -> (artist: Artist, albums: [Album]) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getArtist", params: ["id": id], as: GetArtistPayload.self)
        let artist = payload.artist.toRecord(updatedAt: now)
        let albums = payload.artist.album.map { $0.toRecord(updatedAt: now) }
        return (artist, albums)
    }

    /// Fetches an album and its tracks from `getAlbum.view?id=`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"album":{"id":…,"title":…,"song":[…]}}
    /// ```
    /// - Returns: The `Album` record and all of its `[Track]` records.
    public func getAlbum(id: String) async throws -> (album: Album, tracks: [Track]) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getAlbum", params: ["id": id], as: GetAlbumPayload.self)
        let album = payload.album.toRecord(updatedAt: now)
        let tracks = payload.album.song.map { $0.toRecord(updatedAt: now) }
        return (album, tracks)
    }

    // MARK: - Star-state-aware fetch variants (65x.2)

    /// A per-item star/rating/play-count snapshot from the server response.
    ///
    /// Carried on the DTO layer only — never persisted to the GRDB v1 schema.
    /// Keyed by the item's Subsonic `id`; used by the browse UI to display and
    /// toggle star state without adding GRDB columns.
    public struct StarState {
        /// Whether the item is currently starred on the server.
        public var starred: Bool
        /// 0–5 user rating; `nil` when no rating has been set.
        public var userRating: Int?
        /// Number of times the item has been played (server-side).
        /// `nil` when the endpoint did not return a play count.
        public var playCount: Int?

        public init(starred: Bool, userRating: Int?, playCount: Int? = nil) {
            self.starred = starred
            self.userRating = userRating
            self.playCount = playCount
        }
    }

    /// Like `getAlbum(id:)` but also returns per-track `StarState` keyed by track ID,
    /// and the album's own `StarState`.
    ///
    /// Used by the browse UI (AlbumDetailView) to reflect server-side star state
    /// without writing to the GRDB schema.
    public func getAlbumWithStarState(id: String) async throws -> (
        album: Album,
        albumStarState: StarState,
        tracks: [Track],
        trackStarStates: [String: StarState]
    ) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getAlbum", params: ["id": id], as: GetAlbumPayload.self)
        let album = payload.album.toRecord(updatedAt: now)
        let albumStarState = StarState(
            starred: payload.album.albumDTO.starred,
            userRating: payload.album.albumDTO.userRating,
            playCount: payload.album.albumDTO.playCount
        )
        let tracks = payload.album.song.map { $0.toRecord(updatedAt: now) }
        var trackStarStates: [String: StarState] = [:]
        for dto in payload.album.song {
            trackStarStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        return (album, albumStarState, tracks, trackStarStates)
    }

    /// Like `getArtist(id:)` but also returns the artist's `StarState`.
    ///
    /// Used by the browse UI (ArtistDetailView) to reflect server-side star state.
    public func getArtistWithStarState(id: String) async throws -> (
        artist: Artist,
        artistStarState: StarState,
        albums: [Album]
    ) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getArtist", params: ["id": id], as: GetArtistPayload.self)
        let artist = payload.artist.toRecord(updatedAt: now)
        let artistStarState = StarState(starred: payload.artist.starred, userRating: nil)
        let albums = payload.artist.album.map { $0.toRecord(updatedAt: now) }
        return (artist, artistStarState, albums)
    }

    /// Fetches a list of albums from `getAlbumList2.view`.
    ///
    /// - Parameters:
    ///   - type: The list ordering/filter type.
    ///   - size: Maximum number of albums to return (1–500; defaults to 10).
    ///   - offset: Offset into the album list for pagination.
    /// - Returns: `[Album]` records.
    public func getAlbumList2(
        type: AlbumListType,
        size: Int = 10,
        offset: Int = 0
    ) async throws -> [Album] {
        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = [
            "type":   type.rawValue,
            "size":   String(size),
            "offset": String(offset),
        ]
        let payload = try await fetch("getAlbumList2", params: params, as: GetAlbumList2Payload.self)
        return payload.albumList2.album.map { $0.toRecord(updatedAt: now) }
    }

    /// Like `getAlbumList2` but also returns per-album `StarState` keyed by album ID.
    ///
    /// Used by BrowseAlbumsView to show starred indicators and play counts in
    /// album grid cells without storing those values in the GRDB schema.
    public func getAlbumList2WithStarState(
        type: AlbumListType,
        size: Int = 10,
        offset: Int = 0
    ) async throws -> (albums: [Album], starStates: [String: StarState]) {
        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = [
            "type":   type.rawValue,
            "size":   String(size),
            "offset": String(offset),
        ]
        let payload = try await fetch("getAlbumList2", params: params, as: GetAlbumList2Payload.self)
        let albums = payload.albumList2.album.map { $0.toRecord(updatedAt: now) }
        var starStates: [String: StarState] = [:]
        for dto in payload.albumList2.album {
            starStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        return (albums, starStates)
    }

    /// Like `search3` but also returns per-album and per-song `StarState` keyed by ID.
    ///
    /// Used by SearchResultsView to show starred indicators in search results.
    public struct SearchResultsWithStarState {
        public let artists: [Artist]
        public let albums: [Album]
        public let songs: [Track]
        public let albumStarStates: [String: StarState]
        public let songStarStates: [String: StarState]

        public init(
            artists: [Artist],
            albums: [Album],
            songs: [Track],
            albumStarStates: [String: StarState],
            songStarStates: [String: StarState]
        ) {
            self.artists = artists
            self.albums = albums
            self.songs = songs
            self.albumStarStates = albumStarStates
            self.songStarStates = songStarStates
        }

        public static let empty = SearchResultsWithStarState(
            artists: [], albums: [], songs: [],
            albumStarStates: [:], songStarStates: [:]
        )
    }

    /// Searches the library and returns star/play-count state alongside the results.
    public func search3WithStarState(
        query: String,
        artistCount: Int = 20,
        albumCount: Int = 20,
        songCount: Int = 20,
        artistOffset: Int = 0,
        albumOffset: Int = 0,
        songOffset: Int = 0
    ) async throws -> SearchResultsWithStarState {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = [
            "query":        query,
            "artistCount":  String(artistCount),
            "albumCount":   String(albumCount),
            "songCount":    String(songCount),
            "artistOffset": String(artistOffset),
            "albumOffset":  String(albumOffset),
            "songOffset":   String(songOffset),
        ]
        let payload = try await fetch("search3", params: params, as: Search3Payload.self)
        let result = payload.searchResult3
        var albumStarStates: [String: StarState] = [:]
        for dto in result.album {
            albumStarStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        var songStarStates: [String: StarState] = [:]
        for dto in result.song {
            songStarStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        return SearchResultsWithStarState(
            artists: result.artist.map { $0.toRecord(updatedAt: now) },
            albums:  result.album.map  { $0.toRecord(updatedAt: now) },
            songs:   result.song.map   { $0.toRecord(updatedAt: now) },
            albumStarStates: albumStarStates,
            songStarStates:  songStarStates
        )
    }

    /// Like `getSongsByGenre` but also returns per-song `StarState` keyed by track ID.
    ///
    /// Used by GenreDetailView to show starred indicators in genre song lists.
    public func getSongsByGenreWithStarState(
        genre: String,
        count: Int = 10,
        offset: Int = 0
    ) async throws -> (tracks: [Track], starStates: [String: StarState]) {
        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = [
            "genre":  genre,
            "count":  String(count),
            "offset": String(offset),
        ]
        let payload = try await fetch("getSongsByGenre", params: params, as: GetSongsByGenrePayload.self)
        let tracks = payload.songsByGenre.song.map { $0.toRecord(updatedAt: now) }
        var starStates: [String: StarState] = [:]
        for dto in payload.songsByGenre.song {
            starStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        return (tracks, starStates)
    }

    /// Fetches all genres from `getGenres.view`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"genres":{"genre":[{"value":"Rock","songCount":12,"albumCount":3}]}}
    /// ```
    public func getGenres() async throws -> [Genre] {
        let payload = try await fetch("getGenres", params: [:], as: GetGenresPayload.self)
        return payload.genres.genre
    }

    /// Fetches a random page of songs from `getRandomSongs.view` (fnv.11).
    ///
    /// Backs the CarPlay "Songs" browse: a flat, no-text-input song list the
    /// user can tap to start playback with the rest of the page queued.
    /// Subsonic caps `size` at 500.
    public func getRandomSongs(size: Int = 100) async throws -> [Track] {
        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = ["size": String(min(max(size, 1), 500))]
        let payload = try await fetch("getRandomSongs", params: params, as: GetRandomSongsPayload.self)
        return payload.randomSongs.song.map { $0.toRecord(updatedAt: now) }
    }

    // MARK: - Search

    /// Result of a `search3` call — artists, albums, and songs that match the query.
    public struct SearchResults {
        public let artists: [Artist]
        public let albums: [Album]
        public let songs: [Track]

        public init(artists: [Artist], albums: [Album], songs: [Track]) {
            self.artists = artists
            self.albums = albums
            self.songs = songs
        }

        /// Convenience empty result — all three arrays are empty.
        public static let empty = SearchResults(artists: [], albums: [], songs: [])
    }

    // MARK: - AlbumListType enum

    /// Ordering/filter modes for `getAlbumList2`.
    public enum AlbumListType: String {
        /// Most recently added albums.
        case newest
        /// Most recently played albums.
        case recent
        /// Most-played albums.
        case frequent
        /// Randomly-selected albums.
        case random
        /// Albums sorted alphabetically by name.
        case alphabeticalByName
    }

    // MARK: - Private payload types for library-browse endpoints

    // getArtists
    private struct GetArtistsPayload: Decodable {
        let artists: ArtistsWrapper

        struct ArtistsWrapper: Decodable {
            let index: [IndexBucket]
        }

        struct IndexBucket: Decodable {
            let name: String
            let artist: [SubsonicArtistDTO]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name   = try c.decode(String.self, forKey: .name)
                artist = (try? c.decode([SubsonicArtistDTO].self, forKey: .artist)) ?? []
            }

            enum CodingKeys: String, CodingKey { case name, artist }
        }
    }

    // getArtist
    private struct GetArtistPayload: Decodable {
        let artist: ArtistDetail

        struct ArtistDetail: Decodable {
            let id: String
            let name: String
            let albumCount: Int?
            let coverArt: String?
            let album: [SubsonicAlbumDTO]
            /// True when the Subsonic `starred` date-string field is present.
            let starred: Bool

            func toRecord(updatedAt: Int) -> Artist {
                Artist(
                    id: id,
                    name: name,
                    sortName: nil,
                    albumCount: albumCount ?? album.count,
                    coverArt: coverArt,
                    updatedAt: updatedAt
                )
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id         = try c.decode(String.self, forKey: .id)
                name       = try c.decode(String.self, forKey: .name)
                albumCount = try? c.decodeIfPresent(Int.self, forKey: .albumCount)
                coverArt   = try? c.decodeIfPresent(String.self, forKey: .coverArt)
                album      = (try? c.decode([SubsonicAlbumDTO].self, forKey: .album)) ?? []
                let starredValue = try? c.decodeIfPresent(String.self, forKey: .starredField)
                starred = starredValue != nil
            }

            enum CodingKeys: String, CodingKey {
                case id, name, albumCount, coverArt, album
                case starredField = "starred"
            }
        }
    }

    // getAlbum
    private struct GetAlbumPayload: Decodable {
        let album: AlbumDetail

        struct AlbumDetail: Decodable {
            let albumDTO: SubsonicAlbumDTO
            let song: [SubsonicTrackDTO]

            func toRecord(updatedAt: Int) -> Album { albumDTO.toRecord(updatedAt: updatedAt) }

            init(from decoder: Decoder) throws {
                albumDTO = try SubsonicAlbumDTO(from: decoder)
                let c    = try decoder.container(keyedBy: CodingKeys.self)
                song     = (try? c.decode([SubsonicTrackDTO].self, forKey: .song)) ?? []
            }

            enum CodingKeys: String, CodingKey { case song }
        }
    }

    // getAlbumList2
    private struct GetAlbumList2Payload: Decodable {
        let albumList2: AlbumList2Wrapper

        struct AlbumList2Wrapper: Decodable {
            let album: [SubsonicAlbumDTO]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                album = (try? c.decode([SubsonicAlbumDTO].self, forKey: .album)) ?? []
            }

            enum CodingKeys: String, CodingKey { case album }
        }
    }

    // getGenres
    private struct GetGenresPayload: Decodable {
        let genres: GenresWrapper

        struct GenresWrapper: Decodable {
            let genre: [Genre]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                genre = (try? c.decode([Genre].self, forKey: .genre)) ?? []
            }

            enum CodingKeys: String, CodingKey { case genre }
        }
    }

    // search3
    private struct Search3Payload: Decodable {
        let searchResult3: SearchResult3Wrapper

        struct SearchResult3Wrapper: Decodable {
            let artist: [SubsonicArtistDTO]
            let album: [SubsonicAlbumDTO]
            let song: [SubsonicTrackDTO]

            init(from decoder: Decoder) throws {
                let c  = try decoder.container(keyedBy: CodingKeys.self)
                artist = (try? c.decode([SubsonicArtistDTO].self, forKey: .artist)) ?? []
                album  = (try? c.decode([SubsonicAlbumDTO].self,  forKey: .album))  ?? []
                song   = (try? c.decode([SubsonicTrackDTO].self,  forKey: .song))   ?? []
            }

            enum CodingKeys: String, CodingKey { case artist, album, song }
        }
    }

    // getSongsByGenre
    private struct GetSongsByGenrePayload: Decodable {
        let songsByGenre: SongsByGenreWrapper

        struct SongsByGenreWrapper: Decodable {
            let song: [SubsonicTrackDTO]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                song  = (try? c.decode([SubsonicTrackDTO].self, forKey: .song)) ?? []
            }

            enum CodingKeys: String, CodingKey { case song }
        }
    }

    // getRandomSongs
    private struct GetRandomSongsPayload: Decodable {
        let randomSongs: RandomSongsWrapper

        struct RandomSongsWrapper: Decodable {
            let song: [SubsonicTrackDTO]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                song  = (try? c.decode([SubsonicTrackDTO].self, forKey: .song)) ?? []
            }

            enum CodingKeys: String, CodingKey { case song }
        }
    }
}
