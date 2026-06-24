import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Navidrome / Subsonic REST API client skeleton.
///
/// Mirrors the `XtreamCodesAPI` value-type pattern but with an injectable
/// `URLSession` (passed at init) so the network layer is unit-testable.
///
/// The Subsonic REST envelope wraps every response under the literal JSON key
/// `"subsonic-response"` (hyphen requires a custom `CodingKey` — Swift cannot
/// auto-synthesize a property name for it).
///
/// Auth query parameters (u / t / s / c / v / f) are sourced from
/// `SubsonicAuth.queryItems()` and appended to every request URL.
public struct NavidromeAPI {

    // MARK: - Stored properties

    public let host: URL
    public let username: String
    private let password: String

    /// Injected session — callers pass a stub in tests.
    /// The default session uses a 15-second request timeout.
    public let session: URLSession

    // MARK: - Init

    /// - Parameters:
    ///   - host: Base URL of the Navidrome server (e.g. `https://music.example.com`).
    ///   - username: Subsonic username.
    ///   - password: Subsonic password.
    ///   - session: `URLSession` to use for all requests.  Pass `nil` (the default)
    ///     to use a session configured with a 15-second `timeoutIntervalForRequest`.
    ///     Pass an explicit session in tests to inject a `URLProtocol` stub.
    public init(
        host: URL,
        username: String,
        password: String,
        session: URLSession? = nil
    ) {
        self.host = host
        self.username = username
        self.password = password
        self.session = session ?? NavidromeAPI.makeDefaultSession()
    }

    // MARK: - Typed errors

    public enum APIError: Error, LocalizedError {
        /// The constructed request URL was invalid.
        case invalidURL
        /// Cannot reach the server (DNS / connection refused / no network).
        case unreachable(Error)
        /// The request exceeded the timeout threshold.
        case timedOut
        /// HTTP response was non-2xx.
        case serverError(statusCode: Int)
        /// HTTP 200 but the body is not a Subsonic envelope (HTML error page, wrong server, etc.).
        case notSubsonicServer
        /// The server returned `status == "failed"` with a Subsonic error code and message.
        case subsonicError(code: Int, message: String)
        /// Subsonic error code 40 or 41 — convenience alias surfaced separately so
        /// `a6f.10` can show distinct "wrong credentials" copy without matching on raw codes.
        case authenticationFailed
        /// Successfully received an envelope but the inner payload did not decode.
        case decodingError(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL."
            case .unreachable(let e):
                return "Cannot reach the server: \(e.localizedDescription)"
            case .timedOut:
                return "The request timed out. Check your server address and network."
            case .serverError(let code):
                return "Server error (HTTP \(code))."
            case .notSubsonicServer:
                return "The server did not return a Subsonic response. Verify the server URL."
            case .subsonicError(let code, let message):
                return "Subsonic error \(code): \(message)"
            case .authenticationFailed:
                return "Authentication failed. Check your username and password."
            case .decodingError(let e):
                return "Data error: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Subsonic envelope types

    /// Decoded Subsonic status envelope, without an associated payload.
    /// Used for `ping` and other endpoints that carry no inner object.
    struct SubsonicStatusEnvelope: Decodable {
        let status: String
        let version: String
        let error: SubsonicErrorBody?

        struct SubsonicErrorBody: Decodable {
            let code: Int
            let message: String
        }

        // The outer key is the literal string "subsonic-response" which contains
        // a hyphen — that cannot be expressed as an identifier, so a custom
        // CodingKeys enum is required.
        enum OuterKeys: String, CodingKey {
            case subsonicResponse = "subsonic-response"
        }

        enum InnerKeys: String, CodingKey {
            case status, version, error
        }

        init(from decoder: Decoder) throws {
            let outer = try decoder.container(keyedBy: OuterKeys.self)
            let inner = try outer.nestedContainer(keyedBy: InnerKeys.self, forKey: .subsonicResponse)
            status = try inner.decode(String.self, forKey: .status)
            version = try inner.decode(String.self, forKey: .version)
            error = try inner.decodeIfPresent(SubsonicErrorBody.self, forKey: .error)
        }
    }

    // MARK: - Public API

    /// Checks connectivity and basic auth by calling `ping.view`.
    ///
    /// Returns normally when the server responds with `status == "ok"`.
    /// Throws a mapped `APIError` otherwise.
    public func ping() async throws {
        guard let url = buildURL(endpoint: "ping", params: [:]) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)

        // Decode the status-only envelope (no payload needed for ping).
        let envelope: SubsonicStatusEnvelope
        do {
            envelope = try JSONDecoder().decode(SubsonicStatusEnvelope.self, from: data)
        } catch {
            throw APIError.notSubsonicServer
        }

        try checkStatus(envelope.status, error: envelope.error)
    }

    /// Generic fetch that decodes the Subsonic envelope and returns the inner payload.
    ///
    /// - Parameters:
    ///   - endpoint: Subsonic endpoint name without the `.view` suffix (e.g. `"getArtists"`).
    ///   - params: Additional query parameters for the endpoint.
    ///   - type: Expected `Decodable` payload type.
    /// - Returns: Decoded payload of type `T`.
    /// - Throws: `APIError` for any failure.
    public func fetch<T: Decodable>(
        _ endpoint: String,
        params: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        guard let url = buildURL(endpoint: endpoint, params: params) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)

        // First check that this is a Subsonic envelope at all.
        let statusEnvelope: SubsonicStatusEnvelope
        do {
            statusEnvelope = try JSONDecoder().decode(SubsonicStatusEnvelope.self, from: data)
        } catch {
            throw APIError.notSubsonicServer
        }

        try checkStatus(statusEnvelope.status, error: statusEnvelope.error)

        // Status is "ok" — now decode the full envelope with the typed payload.
        do {
            let wrapper = try JSONDecoder().decode(SubsonicEnvelope<T>.self, from: data)
            return wrapper.payload
        } catch let apiErr as APIError {
            throw apiErr
        } catch {
            throw APIError.decodingError(error)
        }
    }

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

    /// Like `getPlaylist(id:)` but also returns per-track `StarState` keyed by track ID.
    ///
    /// Used by PlaylistDetailView to reflect server-side star state on playlist tracks.
    public func getPlaylistWithStarState(id: String) async throws -> (
        playlist: Playlist,
        tracks: [Track],
        trackStarStates: [String: StarState]
    ) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getPlaylist", params: ["id": id], as: GetPlaylistPayload.self)
        let tracks = payload.playlist.entry.map { $0.toRecord(updatedAt: now) }
        var trackStarStates: [String: StarState] = [:]
        for dto in payload.playlist.entry {
            trackStarStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        return (payload.playlist.playlistMeta, tracks, trackStarStates)
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

    // MARK: - Media streaming URLs (d6q.2)

    /// Builds a `stream.view` URL for the given track ID.
    ///
    /// The URL embeds Subsonic token auth (u/t/s/c/v/f) so it can be
    /// handed directly to VLC without any additional headers.
    ///
    /// - Parameters:
    ///   - trackID: The Subsonic/Navidrome track identifier.
    ///   - maxBitRate: Optional maximum bitrate in kbps.  Pass `nil` to let
    ///     the server stream the original file without transcoding.
    ///   - format: Optional target audio format (e.g. `"mp3"`, `"opus"`).
    ///     Pass `nil` to use the server's default (usually original format).
    /// - Returns: A fully-formed URL ready to feed to VLC, or `nil` if the
    ///   host URL is malformed.
    public func streamURL(trackID: String, maxBitRate: Int? = nil, format: String? = nil) -> URL? {
        var params: [String: String] = ["id": trackID]
        if let maxBitRate { params["maxBitRate"] = String(maxBitRate) }
        if let format { params["format"] = format }
        return buildURL(endpoint: "stream", params: params)
    }

    /// Builds a `getCoverArt.view` URL for the given cover-art ID.
    ///
    /// - Parameters:
    ///   - id: The Subsonic cover-art identifier (from `Track.coverArt` or
    ///     `Album.coverArt`).
    ///   - size: Optional square pixel size for the thumbnail.  Pass `nil`
    ///     to request the full-size image.
    /// - Returns: A fully-formed URL, or `nil` if the host URL is malformed.
    public func coverArtURL(id: String, size: Int? = nil) -> URL? {
        var params: [String: String] = ["id": id]
        if let size { params["size"] = String(size) }
        return buildURL(endpoint: "getCoverArt", params: params)
    }

    // MARK: - Cover-art cache fetch (0xy.2)

    /// Fetches a cover-art image through `ImageCacheService` using a stable
    /// cache key, bypassing the per-request auth-salt cache-busting problem.
    ///
    /// Subsonic auth includes a random salt in every URL, so two calls to
    /// `coverArtURL(id:size:)` for the same artwork produce different URLs.
    /// Keying the cache by those URLs would miss on every render.  Instead this
    /// method derives a stable key from the server host, cover-art ID, and size,
    /// then uses that key for all cache lookups.  Only on a miss is an authed
    /// URL built and used for the network fetch.
    ///
    /// - Parameters:
    ///   - id: The Subsonic cover-art identifier.
    ///   - size: Optional thumbnail pixel size.
    /// - Returns: A `UIImage` from the cache or network, or `nil` on failure.
    #if canImport(UIKit)
    public func fetchCoverArtImage(id: String, size: Int? = nil) async -> UIImage? {
        let hostString = host.absoluteString
        let stableKey = ImageCacheService.coverArtCacheKey(
            host: hostString,
            coverArtID: id,
            size: size
        )
        guard let fetchURL = coverArtURL(id: id, size: size) else { return nil }
        return await ImageCacheService.shared.coverArtImage(stableKey: stableKey, fetchURL: fetchURL)
    }
    #endif

    /// Fetches songs by genre from `getSongsByGenre.view`.
    ///
    /// - Parameters:
    ///   - genre: Genre name to filter by.
    ///   - count: Maximum number of songs to return (1–500; defaults to 10).
    ///   - offset: Offset into the results for pagination.
    /// - Returns: `[Track]` records.
    public func getSongsByGenre(
        genre: String,
        count: Int = 10,
        offset: Int = 0
    ) async throws -> [Track] {
        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = [
            "genre":  genre,
            "count":  String(count),
            "offset": String(offset),
        ]
        let payload = try await fetch("getSongsByGenre", params: params, as: GetSongsByGenrePayload.self)
        return payload.songsByGenre.song.map { $0.toRecord(updatedAt: now) }
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

    /// Searches the library via `search3.view`.
    ///
    /// Returns artists, albums, and songs whose names contain `query`.
    ///
    /// Blank-query behaviour: a nil, empty, or whitespace-only query returns
    /// `SearchResults.empty` immediately without making a network call.  The
    /// UI is expected to debounce, but this provides a defensive safety net.
    ///
    /// Subsonic quirk: when a category has no matches the corresponding array
    /// key is absent from the response entirely.  Each array is decoded as
    /// optional and defaults to `[]`, so all-empty results do not throw.
    ///
    /// - Parameters:
    ///   - query: Search string.
    ///   - artistCount: Maximum number of artist results (default: 20).
    ///   - albumCount: Maximum number of album results (default: 20).
    ///   - songCount: Maximum number of song results (default: 20).
    ///   - artistOffset: Offset into artist results for pagination (default: 0).
    ///   - albumOffset: Offset into album results for pagination (default: 0).
    ///   - songOffset: Offset into song results for pagination (default: 0).
    /// - Returns: A `SearchResults` value containing matched artists, albums, and songs.
    /// - Throws: `APIError` on network or server errors.
    public func search3(
        query: String,
        artistCount: Int = 20,
        albumCount: Int = 20,
        songCount: Int = 20,
        artistOffset: Int = 0,
        albumOffset: Int = 0,
        songOffset: Int = 0
    ) async throws -> SearchResults {
        // Blank-query short-circuit: return empty without hitting the network.
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
        return SearchResults(
            artists: result.artist.map { $0.toRecord(updatedAt: now) },
            albums:  result.album.map  { $0.toRecord(updatedAt: now) },
            songs:   result.song.map   { $0.toRecord(updatedAt: now) }
        )
    }

    // MARK: - Star / unstar / setRating endpoints (65x.2)
    //
    // FAVORITES SEPARATION NOTE:
    // Navidrome `star` is SERVER-SIDE and applies to music tracks, albums, and
    // artists. The app's existing `ProviderManager.toggleFavorite` / `favoriteOrder`
    // system is LOCAL and applies only to radio channels (live streams). These are
    // entirely separate domains and must NOT be merged. A future unified "Favorites"
    // view could combine both for display purposes, but the backing stores remain
    // distinct: server-side Subsonic star vs. local channel favorite order.

    /// Stars (favorites) an item on the Navidrome server via `star.view?id=`.
    ///
    /// Subsonic also supports `albumId` and `artistId` params, but Navidrome
    /// accepts a plain `id` for all three entity types — track, album, or artist.
    ///
    /// Returns normally on `status == "ok"`.  Throws a mapped `APIError` on failure.
    public func star(id: String) async throws {
        guard let url = buildURL(endpoint: "star", params: ["id": id]) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        try decodeWriteOK(data: data)
    }

    /// Removes the star (unfavorites) an item on the Navidrome server via `unstar.view?id=`.
    ///
    /// Returns normally on `status == "ok"`.  Throws a mapped `APIError` on failure.
    public func unstar(id: String) async throws {
        guard let url = buildURL(endpoint: "unstar", params: ["id": id]) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        try decodeWriteOK(data: data)
    }

    /// Sets a 0–5 star rating for an item via `setRating.view?id=&rating=`.
    ///
    /// - Parameters:
    ///   - id: The Subsonic/Navidrome entity ID (track, album, or artist).
    ///   - rating: Integer 0–5.  0 clears the rating; 1–5 set it.
    ///
    /// Returns normally on `status == "ok"`.  Throws a mapped `APIError` on failure.
    public func setRating(id: String, rating: Int) async throws {
        let clampedRating = max(0, min(5, rating))
        guard let url = buildURL(endpoint: "setRating", params: [
            "id": id,
            "rating": String(clampedRating),
        ]) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        try decodeWriteOK(data: data)
    }

    // MARK: - Scrobble endpoints (65x.1)

    /// Reports a track play to the server via `scrobble.view`.
    ///
    /// - Parameters:
    ///   - id: The Subsonic/Navidrome track identifier.
    ///   - submission: `false` = "now playing" notification (track just started);
    ///     `true` = play submission (track played past the scrobble threshold,
    ///     increments play count and reports to Last.fm if configured server-side).
    ///   - time: Unix timestamp in milliseconds at which the track was played.
    ///     Pass `nil` to omit (server uses current time).
    ///
    /// Returns normally when the server responds with `status == "ok"`.
    /// Throws a mapped `APIError` on `status == "failed"` or network error.
    public func scrobble(id: String, submission: Bool, time: Int64? = nil) async throws {
        var params: [String: String] = [
            "id": id,
            "submission": submission ? "true" : "false",
        ]
        if let time { params["time"] = String(time) }

        guard let url = buildURL(endpoint: "scrobble", params: params) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        try decodeWriteOK(data: data)
    }

    // MARK: - Playlist write endpoints (msl.3)

    /// Creates a new playlist with an optional set of initial tracks.
    ///
    /// Subsonic endpoint: `createPlaylist.view?name=<name>&songId=<id>&songId=<id>…`
    ///
    /// Some servers return the new playlist object inside the response; others
    /// return a status-only envelope with no payload.  Both are valid:
    /// - Payload present → return `Playlist`
    /// - Status-only ok → return `nil`
    /// - Status failed → throw the mapped `APIError`
    ///
    /// - Parameters:
    ///   - name: Display name for the new playlist.
    ///   - songIds: Optional list of track IDs to add as the initial content.
    /// - Returns: The created `Playlist` when the server echoes it; `nil` on an empty-ok response.
    public func createPlaylist(name: String, songIds: [String] = []) async throws -> Playlist? {
        var items: [URLQueryItem] = [URLQueryItem(name: "name", value: name)]
        for id in songIds {
            items.append(URLQueryItem(name: "songId", value: id))
        }
        guard let url = buildURLMulti(endpoint: "createPlaylist", items: items) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        return try decodeWriteResponse(data: data, payloadType: CreatePlaylistPayload.self)?.playlist
    }

    /// Updates an existing playlist's metadata and/or track list.
    ///
    /// Subsonic endpoint: `updatePlaylist.view?playlistId=…[&name=…][&comment=…]
    ///   [&public=…][&songIdToAdd=…][&songIndexToRemove=…]`
    ///
    /// All parameters except `playlistId` are optional.  Pass non-nil values only
    /// for the fields you want to change.  Removal uses the track's **index** in the
    /// playlist (0-based), not the song ID — pass `songIndexesToRemove` accordingly.
    ///
    /// Returns on a status-ok response (with or without a payload body).
    /// Throws a mapped `APIError` on status-failed.
    public func updatePlaylist(
        playlistId: String,
        name: String? = nil,
        comment: String? = nil,
        public isPublic: Bool? = nil,
        songIdsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) async throws {
        var items: [URLQueryItem] = [URLQueryItem(name: "playlistId", value: playlistId)]
        if let name      { items.append(URLQueryItem(name: "name",    value: name)) }
        if let comment   { items.append(URLQueryItem(name: "comment", value: comment)) }
        if let isPublic  { items.append(URLQueryItem(name: "public",  value: isPublic ? "true" : "false")) }
        for id    in songIdsToAdd        { items.append(URLQueryItem(name: "songIdToAdd",        value: id)) }
        for index in songIndexesToRemove { items.append(URLQueryItem(name: "songIndexToRemove",  value: String(index))) }

        guard let url = buildURLMulti(endpoint: "updatePlaylist", items: items) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        // updatePlaylist always returns status-only — no payload expected.
        try decodeWriteOK(data: data)
    }

    /// Deletes a playlist by ID.
    ///
    /// Subsonic endpoint: `deletePlaylist.view?id=<id>`
    ///
    /// Returns on a status-ok response.  Throws a mapped `APIError` on failure.
    public func deletePlaylist(id: String) async throws {
        guard let url = buildURL(endpoint: "deletePlaylist", params: ["id": id]) else {
            throw APIError.invalidURL
        }
        let data = try await fetchRawData(from: url, attempt: 1)
        try decodeWriteOK(data: data)
    }

    // MARK: - Playlist endpoints

    /// Fetches all playlists visible to the authenticated user from `getPlaylists.view`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"playlists":{"playlist":[<playlist>]}}
    /// ```
    /// An absent `"playlist"` array (user has no playlists) returns `[]` without throwing.
    public func getPlaylists() async throws -> [Playlist] {
        let payload = try await fetch("getPlaylists", params: [:], as: GetPlaylistsPayload.self)
        return payload.playlists.playlist
    }

    /// Fetches a single playlist and its tracks from `getPlaylist.view?id=`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"playlist":{<playlist fields>, "entry":[<song>]}}
    /// ```
    /// An absent `"entry"` array (empty playlist) returns `[]` tracks without throwing.
    ///
    /// - Parameter id: The Subsonic playlist ID.
    /// - Returns: The `Playlist` value and its `[Track]` entries.
    public func getPlaylist(id: String) async throws -> (playlist: Playlist, tracks: [Track]) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getPlaylist", params: ["id": id], as: GetPlaylistPayload.self)
        let tracks = payload.playlist.entry.map { $0.toRecord(updatedAt: now) }
        return (payload.playlist.playlistMeta, tracks)
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

    // getPlaylists
    private struct GetPlaylistsPayload: Decodable {
        let playlists: PlaylistsWrapper

        struct PlaylistsWrapper: Decodable {
            let playlist: [Playlist]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                playlist = (try? c.decode([Playlist].self, forKey: .playlist)) ?? []
            }

            enum CodingKeys: String, CodingKey { case playlist }
        }
    }

    // getPlaylist
    private struct GetPlaylistPayload: Decodable {
        let playlist: PlaylistDetail

        struct PlaylistDetail: Decodable {
            let playlistMeta: Playlist
            let entry: [SubsonicTrackDTO]

            init(from decoder: Decoder) throws {
                playlistMeta = try Playlist(from: decoder)
                let c        = try decoder.container(keyedBy: CodingKeys.self)
                entry        = (try? c.decode([SubsonicTrackDTO].self, forKey: .entry)) ?? []
            }

            enum CodingKeys: String, CodingKey { case entry }
        }
    }

    // MARK: - Playlist write payload types (msl.3)

    // createPlaylist — some servers echo the new playlist; others return status-only.
    // The outer decoder picks this up from the inner "subsonic-response" container.
    private struct CreatePlaylistPayload: Decodable {
        let playlist: Playlist?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playlist = try? c.decodeIfPresent(Playlist.self, forKey: .playlist)
        }

        enum CodingKeys: String, CodingKey { case playlist }
    }

    // MARK: - Write-response helpers (msl.3)

    /// Decodes a write-endpoint response that may or may not carry a payload.
    ///
    /// - If the envelope status is "ok", decode and return `T`.
    /// - If the envelope status is "ok" but the inner payload is absent, return `nil`.
    /// - If the envelope status is "failed", throw the mapped `APIError`.
    /// - If the data is not a Subsonic envelope at all, throw `.notSubsonicServer`.
    private func decodeWriteResponse<T: Decodable>(
        data: Data,
        payloadType: T.Type
    ) throws -> T? {
        // First validate the status envelope.
        let statusEnvelope: SubsonicStatusEnvelope
        do {
            statusEnvelope = try JSONDecoder().decode(SubsonicStatusEnvelope.self, from: data)
        } catch {
            throw APIError.notSubsonicServer
        }
        try checkStatus(statusEnvelope.status, error: statusEnvelope.error)

        // Status is "ok" — attempt to decode the payload.  Missing payload is fine.
        do {
            let wrapper = try JSONDecoder().decode(SubsonicEnvelope<T>.self, from: data)
            return wrapper.payload
        } catch {
            // The envelope status was "ok" but the payload is absent or unparseable.
            // Treat as a successful write with no returned body.
            return nil
        }
    }

    /// Decodes a write-endpoint response that is always status-only (no payload).
    ///
    /// - status "ok" → returns normally
    /// - status "failed" → throws the mapped `APIError`
    /// - not a Subsonic envelope → throws `.notSubsonicServer`
    private func decodeWriteOK(data: Data) throws {
        let envelope: SubsonicStatusEnvelope
        do {
            envelope = try JSONDecoder().decode(SubsonicStatusEnvelope.self, from: data)
        } catch {
            throw APIError.notSubsonicServer
        }
        try checkStatus(envelope.status, error: envelope.error)
    }

    // MARK: - Private helpers

    private func buildURL(endpoint: String, params: [String: String]) -> URL? {
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
        components?.path = "/rest/\(endpoint).view"

        let auth = SubsonicAuth(username: username, password: password)
        var queryItems = auth.queryItems()

        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    /// Builds a URL with repeated query items (e.g. multiple `songId=` params).
    ///
    /// Unlike `buildURL(endpoint:params:)` which takes a `[String: String]` (one
    /// value per key), this variant accepts a full `[URLQueryItem]` list so the
    /// caller can repeat the same key name multiple times.
    private func buildURLMulti(endpoint: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
        components?.path = "/rest/\(endpoint).view"

        let auth = SubsonicAuth(username: username, password: password)
        var queryItems = auth.queryItems()
        queryItems.append(contentsOf: items)
        components?.queryItems = queryItems
        return components?.url
    }

    /// Performs the HTTP request, handles retries on 5xx, and maps network
    /// errors to typed `APIError` cases.  Returns raw `Data` on success.
    private func fetchRawData(from url: URL, attempt: Int) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw APIError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed:
                throw APIError.unreachable(urlError)
            default:
                throw APIError.unreachable(urlError)
            }
        } catch {
            throw APIError.unreachable(error)
        }

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            // Retry once on 5xx with a 2-second backoff.
            if attempt == 1, (500...599).contains(http.statusCode) {
                try? await Task.sleep(for: .seconds(2))
                return try await fetchRawData(from: url, attempt: 2)
            }
            throw APIError.serverError(statusCode: http.statusCode)
        }

        return data
    }

    /// Checks a decoded `status` value and throws the appropriate `APIError`.
    private func checkStatus(
        _ status: String,
        error: SubsonicStatusEnvelope.SubsonicErrorBody?
    ) throws {
        guard status == "ok" else {
            let code = error?.code ?? 0
            let message = error?.message ?? "Unknown error"
            // Subsonic codes 40 / 41 are auth failures.
            if code == 40 || code == 41 {
                throw APIError.authenticationFailed
            }
            throw APIError.subsonicError(code: code, message: message)
        }
    }

    // MARK: - Default session factory

    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }
}

// MARK: - SubsonicEnvelope (generic, for fetch<T>)

/// Full Subsonic envelope that also decodes a typed payload.
///
/// The `"subsonic-response"` outer key contains the status fields AND the
/// endpoint-specific payload as a sibling key (e.g. `"artists"`, `"album"`, etc.).
/// Since the payload key name varies per endpoint, we decode `T` from the inner
/// container using a dynamic `CodingKey`.
///
/// This type is `fileprivate` — only `NavidromeAPI.fetch` needs it.
private struct SubsonicEnvelope<Payload: Decodable>: Decodable {
    let payload: Payload

    enum OuterKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKeys.self)
        // Decode the payload from the inner object — `T` must provide its own
        // `CodingKeys` that match the Subsonic field names.
        payload = try outer.decode(Payload.self, forKey: .subsonicResponse)
    }
}

// MARK: - CustomStringConvertible / CustomDebugStringConvertible

extension NavidromeAPI: CustomStringConvertible {
    public var description: String {
        "NavidromeAPI(host: \(host), username: \(username))"
    }
}

extension NavidromeAPI: CustomDebugStringConvertible {
    public var debugDescription: String {
        "NavidromeAPI(host: \(host), username: \(username), password: <redacted>)"
    }
}
