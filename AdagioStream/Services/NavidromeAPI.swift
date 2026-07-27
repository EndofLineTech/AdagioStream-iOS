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

    /// Delay before the single 5xx retry. Tests pass `.zero` to avoid real sleeps.
    private let retryDelay: Duration

    // MARK: - Init

    /// - Parameters:
    ///   - host: Base URL of the Navidrome server (e.g. `https://music.example.com`).
    ///   - username: Subsonic username.
    ///   - password: Subsonic password.
    ///   - session: `URLSession` to use for all requests.  Pass `nil` (the default)
    ///     to use a session configured with a 15-second `timeoutIntervalForRequest`.
    ///     Pass an explicit session in tests to inject a `URLProtocol` stub.
    ///   - retryDelay: Delay before the single 5xx retry. Tests pass `.zero`.
    public init(
        host: URL,
        username: String,
        password: String,
        session: URLSession? = nil,
        retryDelay: Duration = .seconds(2)
    ) {
        self.host = host
        self.username = username
        self.password = password
        self.session = session ?? NavidromeAPI.makeDefaultSession()
        self.retryDelay = retryDelay
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

    /// Builds a `download.view` URL for the given track ID.
    ///
    /// Unlike `stream.view` (which can transcode to a different format/bitrate),
    /// `download.view` always returns the original, untranscoded file as stored
    /// on the server.  Use this for offline downloads; use `streamURL` for
    /// real-time playback where transcoding is acceptable.
    ///
    /// The URL embeds Subsonic token auth (u/t/s/c/v/f) so it can be used
    /// directly in a `URLSession` download task without additional headers.
    ///
    /// - Parameter trackID: The Subsonic/Navidrome track identifier.
    /// - Returns: A fully-formed URL ready for a download task, or `nil` if the
    ///   host URL is malformed.
    public func downloadURL(trackID: String) -> URL? {
        buildURL(endpoint: "download", params: ["id": trackID])
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
            if RetryOnServerError.shouldRetry(attempt: attempt, statusCode: http.statusCode) {
                await RetryOnServerError.wait(retryDelay)
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
