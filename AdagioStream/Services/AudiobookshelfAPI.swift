import Foundation

/// Audiobookshelf REST client. Mirrors `NavidromeAPI`'s value-type shape, but
/// auth is JWT via `AudiobookshelfAuth` (Bearer header, 401 → refresh → retry)
/// rather than per-request salt/hash query params.
///
/// All GET requests route through `auth.authorizedData(for:)` so the access
/// token is injected and rotated transparently. Streaming and cover-art URLs
/// (where headers can't be set) take the token as a `?token=` query param.
///
/// `contentUrl` and cover paths from the server are SERVER-RELATIVE — every URL
/// builder here resolves against the provider base URL so reverse-proxy
/// subpaths work.
public struct AudiobookshelfAPI {

    // MARK: - Errors

    public enum APIError: Error, LocalizedError {
        case invalidURL
        case auth(AudiobookshelfAuth.AuthError)
        case serverError(statusCode: Int)
        case decodingError(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL."
            case .auth(let e): return e.errorDescription
            case .serverError(let code): return "Server error (HTTP \(code))."
            case .decodingError(let e): return "Data error: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Stored properties

    public let host: URL
    public let auth: AudiobookshelfAuth

    public init(host: URL, auth: AudiobookshelfAuth) {
        self.host = host
        self.auth = auth
    }

    // MARK: - Libraries

    /// `GET /api/libraries`, filtered by `mediaType` (per-library flag, not a
    /// query filter — the server has no server-side media-type filter).
    public func libraries(mediaType: String) async throws -> [ABSLibraryDTO] {
        let response: ABSLibrariesResponse = try await get("/api/libraries")
        return response.libraries.filter { $0.mediaType == mediaType }
    }

    /// `GET /api/libraries`, filtered to `mediaType == "book"`.
    public func bookLibraries() async throws -> [ABSLibraryDTO] {
        try await libraries(mediaType: "book")
    }

    /// `GET /api/libraries`, filtered to `mediaType == "podcast"`.
    public func podcastLibraries() async throws -> [ABSLibraryDTO] {
        try await libraries(mediaType: "podcast")
    }

    /// `GET /api/libraries/{id}/items` — full book list for one library.
    /// `limit=0` returns all; `minified=1` keeps the payload small.
    public func items(inLibrary libraryID: String, sort: String = "media.metadata.title") async throws -> [ABSLibraryItemDTO] {
        let response: ABSLibraryItemsResponse = try await get(
            "/api/libraries/\(libraryID)/items",
            query: [
                "limit": "0",
                "page": "0",
                "minified": "1",
                "sort": sort,
            ]
        )
        return response.results
    }

    /// `GET /api/items/{id}?expanded=1&include=progress` — item detail with this
    /// user's progress embedded and full `media.chapters[]`.
    public func item(id: String) async throws -> ABSLibraryItemDTO {
        try await get("/api/items/\(id)", query: ["expanded": "1", "include": "progress"])
    }

    /// `GET /api/me` — the current user, including `permissions.download`. Used
    /// to gate the download affordance (E3 / mkj.1). The server still 403s the
    /// file endpoint if the permission is missing, so this is a UI hint only.
    public func canDownload() async -> Bool {
        guard let me: ABSUserDTO = try? await get("/api/me") else { return false }
        return me.permissions?.download ?? false
    }

    // MARK: - Media URLs (token-in-query — no headers possible)

    /// Cover art URL: `GET /api/items/{id}/cover?width=&format=&token=`.
    /// Returns `nil` until first login (no access token yet).
    public func coverURL(itemID: String, width: Int = 400, format: String = "webp") async -> URL? {
        guard let token = await auth.currentAccessToken() else { return nil }
        return buildURL("/api/items/\(itemID)/cover", query: [
            "width": String(width),
            "format": format,
            "token": token,
        ])
    }

    /// Resolves a SERVER-RELATIVE content path (e.g. from `contentUrl`) against
    /// the provider base URL and appends the access token. Absolute paths and
    /// reverse-proxy subpaths both resolve correctly.
    public func streamURL(contentPath: String) async -> URL? {
        guard let token = await auth.currentAccessToken() else { return nil }
        return buildURL(contentPath, query: ["token": token])
    }

    // MARK: - Per-file download (E3 / mkj.1)

    /// URL for `GET /api/items/{id}/file/{ino}/download`. The access token goes
    /// on the `Authorization: Bearer` header (set by the download task), not the
    /// query — short-lived JWTs shouldn't leak into URLs/logs.
    public func fileDownloadURL(itemID: String, ino: String) -> URL? {
        buildURL("/api/items/\(itemID)/file/\(ino)/download", query: [:])
    }

    /// Current access token for authorizing a background download task. Returns
    /// `nil` before first login; routes through the auth actor so a live token
    /// (post-refresh) is used.
    public func currentAccessToken() async -> String? {
        await auth.currentAccessToken()
    }

    /// Forces a token refresh and returns the fresh access token, for re-authing a
    /// background download task that 401'd on a stale snapshot token (ymf.5).
    public func refreshedAccessToken(stale: String?) async -> String? {
        await auth.refreshedAccessToken(stale: stale)
    }

    // MARK: - Batched progress sync (E3 / mkj.2)

    /// `PATCH /api/me/progress/batch/update` — flushes queued offline progress in
    /// one request. Body is a BARE JSON array of per-book progress objects
    /// (confirmed against the ABS `MeController.batchUpdateMediaProgress`
    /// source). Returns the HTTP status; does not throw on non-2xx so the caller
    /// can decide whether to keep the queue.
    @discardableResult
    public func batchUpdateProgress(_ updates: [ABSProgressUpdate]) async throws -> Int {
        guard !updates.isEmpty else { return 200 }
        let payload = updates.map { u -> [String: Any] in
            var entry: [String: Any] = [
                "libraryItemId": u.libraryItemId,
                "currentTime": u.currentTime,
                "duration": u.duration,
                "progress": u.progress,
                "isFinished": u.isFinished,
                "lastUpdate": u.lastUpdate,
            ]
            // episodeId is only present for podcast episodes — books must keep
            // serializing exactly as before (no episodeId key at all).
            if let episodeId = u.episodeId {
                entry["episodeId"] = episodeId
            }
            return entry
        }
        guard let url = buildURL("/api/me/progress/batch/update", query: [:]) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, http) = try await auth.authorizedData(for: req)
            return http.statusCode
        } catch let authError as AudiobookshelfAuth.AuthError {
            throw APIError.auth(authError)
        }
    }

    // MARK: - Playback session (E2 / yu8.2, yu8.3)

    /// MIME types VLC direct-plays. Sent wide so the server returns direct-play
    /// tracks (playMethod 0) instead of transcoding — self-hosted boxes choke on
    /// HLS transcode and have known seek-stall bugs.
    public static let supportedMimeTypes = [
        "audio/mpeg", "audio/mp3",
        "audio/mp4", "audio/m4b", "audio/m4a", "audio/aac", "audio/x-m4a", "audio/x-m4b",
        "audio/flac", "audio/x-flac",
        "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff",
        "audio/ogg", "audio/opus",
    ]

    /// `POST /api/items/{id}/play` (books) or `POST /api/items/{id}/play/{episodeId}`
    /// (podcast episodes, E2 / 72i.1) — opens a playback session. Routes through
    /// `ABSEpisodeProgressKey.playPath` so the episode-vs-book path difference
    /// lives in the one adapter, not duplicated here. The response carries the
    /// global resume `currentTime`, the direct-play `audioTracks[]`, chapters,
    /// and the session id used for sync/close.
    public func openPlaybackSession(itemID: String, episodeID: String? = nil, deviceID: String) async throws -> ABSPlaybackSessionDTO {
        let body: [String: Any] = [
            "deviceInfo": [
                "deviceId": deviceID,
                "clientName": "AdagioStream",
                "clientVersion": "1.0",
            ],
            "mediaPlayer": "VLC",
            "supportedMimeTypes": AudiobookshelfAPI.supportedMimeTypes,
            "forceDirectPlay": false,
            "forceTranscode": false,
        ]
        let path = ABSEpisodeProgressKey(libraryItemId: itemID, episodeId: episodeID).playPath
        return try await post(path, body: body)
    }

    /// `POST /api/session/{id}/sync` — reports progress. `currentTime` is
    /// book-global. Returns the HTTP status so callers can detect a 404
    /// (expired/foreign session → reopen via `/play`). Does not throw on 404.
    @discardableResult
    public func syncSession(sessionID: String, currentTime: Double, timeListened: Double, duration: Double) async throws -> Int {
        let body: [String: Any] = [
            "currentTime": currentTime,
            "timeListened": timeListened,
            "duration": duration,
        ]
        return try await postStatus("/api/session/\(sessionID)/sync", body: body)
    }

    /// `POST /api/session/{id}/close` — always call on stop; open sessions hold
    /// server resources. Best-effort: swallows errors.
    public func closeSession(sessionID: String) async {
        _ = try? await postStatus("/api/session/\(sessionID)/close", body: [:])
    }

    /// `GET /api/me/items-in-progress` — the Continue Listening list.
    public func itemsInProgress() async throws -> [ABSLibraryItemDTO] {
        let response: ABSItemsInProgressResponse = try await get("/api/me/items-in-progress")
        return response.libraryItems
    }

    // MARK: - Core POST

    /// Authenticated POST that decodes the JSON response as `T`.
    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let (data, http) = try await postRaw(path, body: body)
        guard (200...299).contains(http.statusCode) else {
            throw APIError.serverError(statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Authenticated POST that discards the body and returns the HTTP status.
    private func postStatus(_ path: String, body: [String: Any]) async throws -> Int {
        let (_, http) = try await postRaw(path, body: body)
        return http.statusCode
    }

    private func postRaw(_ path: String, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        guard let url = buildURL(path, query: [:]) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.isEmpty ? Data("{}".utf8) : (try? JSONSerialization.data(withJSONObject: body))
        do {
            return try await auth.authorizedData(for: req)
        } catch let authError as AudiobookshelfAuth.AuthError {
            throw APIError.auth(authError)
        }
    }

    // MARK: - Core GET

    /// Authenticated GET that decodes the JSON body as `T`. Routes through the
    /// auth actor so the Bearer token is injected and the 401→refresh→retry
    /// lifecycle is handled.
    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard let url = buildURL(path, query: query) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await auth.authorizedData(for: req)
        } catch let authError as AudiobookshelfAuth.AuthError {
            throw APIError.auth(authError)
        }

        guard (200...299).contains(http.statusCode) else {
            throw APIError.serverError(statusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // MARK: - URL building (server-relative aware)

    /// Builds a URL by prefixing `host`'s path onto `path` (so reverse-proxy
    /// subpaths are preserved). Delegates to the shared
    /// `AudiobookshelfURL.resolve` so API, stream/cover, login, and refresh URLs
    /// all use one implementation.
    func buildURL(_ path: String, query: [String: String]) -> URL? {
        AudiobookshelfURL.resolve(host: host, path: path, query: query)
    }
}
