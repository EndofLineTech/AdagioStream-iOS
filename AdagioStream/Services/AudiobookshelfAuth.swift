import Foundation

/// One source of truth for resolving an Audiobookshelf server-relative path
/// against a host, preserving any reverse-proxy subpath in `host`.
///
/// `URL(string:relativeTo:)` can't be used: an absolute-path reference (leading
/// `/`) REPLACES the base's entire path, so a subpath host like
/// `https://h/audiobookshelf` loses `/audiobookshelf`. Every ABS URL builder
/// (API, stream/cover, login, refresh) routes through here so the bug is fixed
/// in exactly one place (beads_mobilemusic-ymf.1).
enum AudiobookshelfURL {
    static func resolve(host: URL, path: String, query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // host.path (trailing "/" trimmed) + request path (leading "/" ensured):
        // no double slash, and a root host (empty path) still yields "/...".
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = base + suffix
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }
}

/// Audiobookshelf JWT auth: login, refresh with token rotation, and a
/// 401 → refresh → retry wrapper. JWT-only (min server 2.26.0); no legacy
/// static-token fallback per PO decision.
///
/// Host/username/password live in the `Provider` record. The access + refresh
/// tokens are session secrets and are persisted to the Keychain, keyed per
/// provider id. The refresh token is ROTATED on every refresh — the new value
/// is persisted each time.
///
/// This is an `actor` so concurrent requests can't run two refreshes at once
/// or read a half-written token pair.
public actor AudiobookshelfAuth {

    // MARK: - Token pair

    public struct Tokens: Codable, Equatable {
        public var accessToken: String
        public var refreshToken: String

        public init(accessToken: String, refreshToken: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    /// Non-token user info captured from the login payload (permissions +
    /// progress) for later epics. Not persisted here.
    public struct Session: Equatable {
        public var tokens: Tokens
        public var canDownload: Bool
        public var mediaProgress: [ABSMediaProgressDTO]

        public static func == (lhs: Session, rhs: Session) -> Bool {
            lhs.tokens == rhs.tokens && lhs.canDownload == rhs.canDownload
        }
    }

    // MARK: - Errors

    public enum AuthError: Error, LocalizedError {
        case invalidURL
        case loginFailed(statusCode: Int)
        case refreshFailed(statusCode: Int)
        /// Refresh itself failed — caller must force re-login (tokens cleared).
        case reauthRequired
        case malformedResponse
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL."
            case .loginFailed(let code): return "Login failed (HTTP \(code)). Check your username and password."
            case .refreshFailed(let code): return "Session refresh failed (HTTP \(code))."
            case .reauthRequired: return "Your session expired. Please sign in again."
            case .malformedResponse: return "The server response was not in the expected format."
            case .network(let e): return "Cannot reach the server: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Stored properties

    public let host: URL
    private let username: String
    private let password: String
    private let session: URLSession
    /// Keychain key under which this provider's tokens are stored.
    private let tokenStoreKey: String

    private var tokens: Tokens?

    /// Coalesces concurrent refreshes. Two authed requests near expiry both 401
    /// on the same stale access token; without this the second refresh would POST
    /// the already-rotated (now-invalid) refresh token, get rejected, and clear
    /// the freshly-rotated pair — forcing a full re-login (ymf.2). The first 401
    /// starts this task; concurrent callers await it instead of starting a second.
    private var inFlightRefresh: Task<Void, Error>?

    // MARK: - Injection seams (tests override these; production uses Keychain)

    private let loadTokens: (String) -> Tokens?
    private let saveTokens: (Tokens, String) -> Void
    private let clearTokens: (String) -> Void

    // MARK: - Init

    /// - Parameters:
    ///   - providerID: Provider UUID string — namespaces the Keychain token entry.
    ///   - session: Injectable for tests. Default uses a 15s request timeout.
    public init(
        host: URL,
        username: String,
        password: String,
        providerID: String,
        session: URLSession? = nil,
        loadTokens: ((String) -> Tokens?)? = nil,
        saveTokens: ((Tokens, String) -> Void)? = nil,
        clearTokens: ((String) -> Void)? = nil
    ) {
        self.host = host
        self.username = username
        self.password = password
        self.tokenStoreKey = "abs.tokens.\(providerID)"
        self.session = session ?? AudiobookshelfAuth.makeDefaultSession()
        self.loadTokens = loadTokens ?? AudiobookshelfAuth.keychainLoad
        self.saveTokens = saveTokens ?? AudiobookshelfAuth.keychainSave
        self.clearTokens = clearTokens ?? AudiobookshelfAuth.keychainClear
        self.tokens = self.loadTokens(tokenStoreKey)
    }

    // MARK: - Login

    /// `POST /login` with `x-return-tokens: true` so the refresh token comes in
    /// the body. Persists the returned token pair and returns the session.
    @discardableResult
    public func login() async throws -> Session {
        // OIDC/SSO providers have no password — an empty password means the
        // Keychain tokens were lost. Never POST empty creds (that returns a 401
        // "check your username and password", which is wrong for SSO); demand
        // re-auth so the UI routes back to the SSO flow.
        guard !password.isEmpty else { throw AuthError.reauthRequired }
        guard let url = AudiobookshelfURL.resolve(host: host, path: "/login") else { throw AuthError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-return-tokens")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.loginFailed(statusCode: code)
        }

        let payload: LoginResponse
        do {
            payload = try JSONDecoder().decode(LoginResponse.self, from: data)
        } catch {
            throw AuthError.malformedResponse
        }
        guard let access = payload.user?.accessToken,
              let refresh = payload.refreshToken ?? payload.user?.refreshToken else {
            throw AuthError.malformedResponse
        }

        let pair = Tokens(accessToken: access, refreshToken: refresh)
        persist(pair)
        return Session(
            tokens: pair,
            canDownload: payload.user?.permissions?.download ?? false,
            mediaProgress: payload.user?.mediaProgress ?? []
        )
    }

    // MARK: - Authenticated request

    /// Runs an authenticated request, injecting `Authorization: Bearer`. On a
    /// 401 it refreshes once (rotating the refresh token), retries, and returns
    /// the retried response. If no tokens are present it logs in first.
    ///
    /// - Parameter build: Builds the request from a base `URLRequest` whose URL
    ///   is already `endpoint` resolved against `host`. Callers set method,
    ///   query, and body; auth headers are added here.
    public func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if tokens == nil {
            _ = try await login()
        }
        guard var access = tokens?.accessToken else { throw AuthError.reauthRequired }

        var req = request
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await perform(req)
        var http = response as? HTTPURLResponse

        if http?.statusCode == 401 {
            try await refreshIfNeeded(staleAccessToken: access)  // throws .reauthRequired on failure
            guard let newAccess = tokens?.accessToken else { throw AuthError.reauthRequired }
            access = newAccess
            var retry = request
            retry.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            (data, response) = try await perform(retry)
            http = response as? HTTPURLResponse
        }

        guard let finalHTTP = http else { throw AuthError.malformedResponse }
        return (data, finalHTTP)
    }

    /// Current access token, for building token-in-query URLs (streaming, cover
    /// art) where headers can't be set. `nil` until first login.
    public func currentAccessToken() -> String? { tokens?.accessToken }

    /// Forces a token rotation and returns the fresh access token. Used when a
    /// background download task 401s on a snapshot token that went stale while
    /// OS-deferred (ymf.5). Reuses the same coalesced refresh as the 401-retry
    /// path so a wave of file-task 401s triggers exactly one refresh. Returns
    /// `nil` if reauth is required (refresh failed / no tokens).
    public func refreshedAccessToken(stale: String?) async -> String? {
        do {
            try await refreshIfNeeded(staleAccessToken: stale ?? tokens?.accessToken ?? "")
        } catch {
            return nil
        }
        return tokens?.accessToken
    }

    /// Seeds a token pair obtained out-of-band (the OpenID/SSO flow) into the
    /// same Keychain storage a password login uses. After this, refresh/rotation
    /// and 401-retry work identically — an OIDC provider never calls `login()`
    /// (it has no password). See `AudiobookshelfOIDC`.
    public func seedTokens(_ pair: Tokens) {
        persist(pair)
    }

    // MARK: - Refresh (rotates the refresh token)

    /// Refreshes at most once for a wave of concurrent 401s. If someone already
    /// rotated the token since this caller's 401 (its access token changed), the
    /// caller just retries with the new token — no refresh. Otherwise it joins
    /// (or starts) the single in-flight refresh. Preserves `refresh()`'s
    /// failure contract: a failed refresh clears tokens and throws `.reauthRequired`.
    private func refreshIfNeeded(staleAccessToken: String) async throws {
        // Someone else already refreshed while we were suspended — reuse it.
        if let current = tokens?.accessToken, current != staleAccessToken { return }

        if let existing = inFlightRefresh {
            try await existing.value
            return
        }
        let task = Task { try await self.refresh() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        try await task.value
    }

    /// `POST /auth/refresh` with `x-refresh-token`. Persists the ROTATED pair on
    /// success. On failure, clears tokens and throws `.reauthRequired`.
    public func refresh() async throws {
        guard let current = tokens?.refreshToken else {
            forgetTokens()
            throw AuthError.reauthRequired
        }
        guard let url = AudiobookshelfURL.resolve(host: host, path: "/auth/refresh") else { throw AuthError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(current, forHTTPHeaderField: "x-refresh-token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await perform(req)
        } catch {
            // Network failure on refresh — surface as reauth-required so the
            // caller re-logs-in rather than silently retrying with a dead token.
            forgetTokens()
            throw AuthError.reauthRequired
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            forgetTokens()
            throw AuthError.reauthRequired
        }

        guard let payload = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              let access = payload.user?.accessToken ?? payload.accessToken,
              let newRefresh = payload.refreshToken ?? payload.user?.refreshToken else {
            forgetTokens()
            throw AuthError.reauthRequired
        }

        persist(Tokens(accessToken: access, refreshToken: newRefresh))
    }

    // MARK: - Token persistence

    private func persist(_ pair: Tokens) {
        tokens = pair
        saveTokens(pair, tokenStoreKey)
    }

    private func forgetTokens() {
        tokens = nil
        clearTokens(tokenStoreKey)
    }

    // MARK: - Networking helper

    private func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw AuthError.network(error)
        }
    }

    // MARK: - Keychain default token store

    private static func keychainLoad(_ key: String) -> Tokens? {
        guard let data = KeychainService.load(for: key) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private static func keychainSave(_ tokens: Tokens, _ key: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? KeychainService.save(data, for: key)
    }

    private static func keychainClear(_ key: String) {
        KeychainService.delete(for: key)
    }

    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }
}

// MARK: - Login / refresh response DTOs

/// `POST /login` response. `refreshToken` is top-level when `x-return-tokens`
/// is set; some server versions also echo it under `user`. `accessToken` lives
/// under `user`.
struct LoginResponse: Decodable {
    let user: ABSUserDTO?
    let refreshToken: String?
}

/// `POST /auth/refresh` response — shape mirrors login (token fields may sit
/// top-level or under `user` depending on server version).
struct RefreshResponse: Decodable {
    let user: ABSUserDTO?
    let accessToken: String?
    let refreshToken: String?
}

/// The `user` object from login/refresh.
public struct ABSUserDTO: Decodable {
    public let accessToken: String?
    public let refreshToken: String?
    public let permissions: ABSPermissionsDTO?
    public let mediaProgress: [ABSMediaProgressDTO]?
}

/// `user.permissions` — only `download` is captured for later epics.
public struct ABSPermissionsDTO: Decodable {
    public let download: Bool?
}
