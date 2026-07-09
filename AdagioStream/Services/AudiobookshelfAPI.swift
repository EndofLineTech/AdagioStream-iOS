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

    /// `GET /api/libraries`, filtered to `mediaType == "book"` (per-library flag,
    /// not a query filter).
    public func bookLibraries() async throws -> [ABSLibraryDTO] {
        let response: ABSLibrariesResponse = try await get("/api/libraries")
        return response.libraries.filter(\.isBook)
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

    /// Builds a URL by resolving `path` against `host` (so reverse-proxy
    /// subpaths in `host` are preserved) and appending query items.
    func buildURL(_ path: String, query: [String: String]) -> URL? {
        // Resolve the path against the base to honor subpath deployments.
        guard let resolved = URL(string: path, relativeTo: host)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }
}
