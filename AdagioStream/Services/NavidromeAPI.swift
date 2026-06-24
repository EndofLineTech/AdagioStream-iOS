import Foundation

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
