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
            }

            enum CodingKeys: String, CodingKey { case id, name, albumCount, coverArt, album }
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
