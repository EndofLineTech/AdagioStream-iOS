import XCTest
@testable import AdagioStream

// Covers the subtle auth logic: refresh rotates + persists the new refresh
// token, and a 401 triggers exactly one refresh-then-retry.

final class AudiobookshelfAuthTests: XCTestCase {

    private var session: URLSession!
    /// In-memory token store shared with the actor via injection.
    private var stored: [String: AudiobookshelfAuth.Tokens] = [:]

    override func setUp() {
        super.setUp()
        MockURLProtocolHandler.reset()
        session = MockURLProtocolHandler.makeSession()
        stored = [:]
    }

    override func tearDown() {
        MockURLProtocolHandler.reset()
        super.tearDown()
    }

    private func makeAuth(seed: AudiobookshelfAuth.Tokens? = nil,
                          host: String = "https://abs.example.com") -> AudiobookshelfAuth {
        if let seed { stored["k"] = seed }
        return AudiobookshelfAuth(
            host: URL(string: host)!,
            username: "alice",
            password: "sesame",
            providerID: "PID",
            session: session,
            loadTokens: { _ in self.stored["k"] },
            saveTokens: { t, _ in self.stored["k"] = t },
            clearTokens: { _ in self.stored["k"] = nil }
        )
    }

    // MARK: - login persists tokens + captures permissions

    func testLoginParsesTokensAndPermissions() async throws {
        MockURLProtocolHandler.responseQueue = [
            .init(json: """
                {"user":{"accessToken":"A1","permissions":{"download":true},
                 "mediaProgress":[{"currentTime":10.0,"progress":0.5,"isFinished":false}]},
                 "refreshToken":"R1"}
                """)
        ]
        let auth = makeAuth()
        let sessionResult = try await auth.login()

        XCTAssertEqual(sessionResult.tokens.accessToken, "A1")
        XCTAssertEqual(sessionResult.tokens.refreshToken, "R1")
        XCTAssertTrue(sessionResult.canDownload)
        XCTAssertEqual(stored["k"]?.refreshToken, "R1", "tokens must persist to the store")
    }

    // MARK: - ymf.1: login/refresh preserve a reverse-proxy subpath in the host

    func testLoginHitsSubpath() async throws {
        MockURLProtocolHandler.responseQueue = [
            .init(json: #"{"user":{"accessToken":"A1"},"refreshToken":"R1"}"#)
        ]
        let auth = makeAuth(host: "https://h/audiobookshelf")
        _ = try await auth.login()

        let url = MockURLProtocolHandler.capturedRequests.last?.url
        XCTAssertEqual(url?.absoluteString, "https://h/audiobookshelf/login",
                       "login must preserve the subpath, not resolve to https://h/login")
    }

    func testRefreshHitsSubpath() async throws {
        let auth = makeAuth(seed: .init(accessToken: "A1", refreshToken: "R1"),
                            host: "https://h/audiobookshelf")
        MockURLProtocolHandler.responseQueue = [
            .init(json: #"{"user":{"accessToken":"A2"},"refreshToken":"R2"}"#)
        ]
        try await auth.refresh()

        let url = MockURLProtocolHandler.capturedRequests.last?.url
        XCTAssertEqual(url?.absoluteString, "https://h/audiobookshelf/auth/refresh",
                       "refresh must preserve the subpath, not resolve to https://h/auth/refresh")
    }

    // MARK: - refresh rotates and persists the new refresh token

    func testRefreshRotatesRefreshToken() async throws {
        let auth = makeAuth(seed: .init(accessToken: "A1", refreshToken: "R1"))
        MockURLProtocolHandler.responseQueue = [
            .init(json: #"{"user":{"accessToken":"A2"},"refreshToken":"R2"}"#)
        ]

        try await auth.refresh()

        XCTAssertEqual(stored["k"]?.accessToken, "A2")
        XCTAssertEqual(stored["k"]?.refreshToken, "R2", "refresh token must rotate to the new value")

        // The refresh request must carry the OLD refresh token in the header.
        let sentHeader = MockURLProtocolHandler.capturedRequests.last?
            .value(forHTTPHeaderField: "x-refresh-token")
        XCTAssertEqual(sentHeader, "R1")
    }

    // MARK: - refresh failure forces re-login (tokens cleared)

    func testRefreshFailureClearsTokens() async {
        let auth = makeAuth(seed: .init(accessToken: "A1", refreshToken: "R1"))
        MockURLProtocolHandler.responseQueue = [.init(json: "{}", statusCode: 401)]

        do {
            try await auth.refresh()
            XCTFail("Expected reauthRequired")
        } catch AudiobookshelfAuth.AuthError.reauthRequired {
            XCTAssertNil(stored["k"], "a failed refresh must clear the token pair")
        } catch {
            XCTFail("Expected reauthRequired, got \(error)")
        }
    }

    // MARK: - OIDC provider with lost tokens must demand re-auth, not empty login

    func testEmptyPasswordLoginThrowsReauthWithoutNetworkCall() async {
        // OIDC provider (empty creds), tokens lost from the Keychain.
        let auth = AudiobookshelfAuth(
            host: URL(string: "https://abs.example.com")!,
            username: "", password: "",
            providerID: "PID",
            session: session,
            loadTokens: { _ in nil },
            saveTokens: { _, _ in },
            clearTokens: { _ in }
        )
        do {
            _ = try await auth.login()
            XCTFail("Expected reauthRequired")
        } catch AudiobookshelfAuth.AuthError.reauthRequired {
            // Must NOT have POSTed empty creds to /login.
            XCTAssertTrue(MockURLProtocolHandler.capturedRequests.isEmpty,
                          "empty-password login must not hit the network")
        } catch {
            XCTFail("Expected reauthRequired, got \(error)")
        }
    }

    func testAuthorizedRequestWithLostOIDCTokensThrowsReauth() async {
        // authorizedData with no tokens falls into login(); for an OIDC provider
        // that must surface reauthRequired, not a 401 "check your password".
        let auth = AudiobookshelfAuth(
            host: URL(string: "https://abs.example.com")!,
            username: "", password: "",
            providerID: "PID",
            session: session,
            loadTokens: { _ in nil },
            saveTokens: { _, _ in },
            clearTokens: { _ in }
        )
        var req = URLRequest(url: URL(string: "https://abs.example.com/api/me")!)
        req.httpMethod = "GET"
        do {
            _ = try await auth.authorizedData(for: req)
            XCTFail("Expected reauthRequired")
        } catch AudiobookshelfAuth.AuthError.reauthRequired {
            // ok
        } catch {
            XCTFail("Expected reauthRequired, got \(error)")
        }
    }

    // MARK: - 401 on an authed request → refresh → retry succeeds

    func testAuthorizedRequestRetriesAfter401() async throws {
        let auth = makeAuth(seed: .init(accessToken: "STALE", refreshToken: "R1"))
        // 1) first authed GET → 401
        // 2) refresh → new tokens
        // 3) retried GET → 200
        MockURLProtocolHandler.responseQueue = [
            .init(json: "{}", statusCode: 401),
            .init(json: #"{"user":{"accessToken":"FRESH"},"refreshToken":"R2"}"#),
            .init(json: #"{"ok":true}"#, statusCode: 200),
        ]

        var req = URLRequest(url: URL(string: "https://abs.example.com/api/libraries")!)
        req.httpMethod = "GET"
        let (_, http) = try await auth.authorizedData(for: req)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(stored["k"]?.accessToken, "FRESH")
        XCTAssertEqual(stored["k"]?.refreshToken, "R2")

        // The retried GET must use the refreshed access token, not the stale one.
        let retryAuth = MockURLProtocolHandler.capturedRequests.last?
            .value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(retryAuth, "Bearer FRESH")
        XCTAssertEqual(MockURLProtocolHandler.capturedRequests.count, 3)
    }

    // MARK: - ymf.2: two concurrent 401s coalesce into ONE refresh, no logout

    func testConcurrent401sRefreshOnce() async throws {
        let auth = makeAuth(seed: .init(accessToken: "STALE", refreshToken: "R1"))

        // Route by request: refresh POST → new pair; authed GET with the stale
        // token → 401; authed GET with the fresh token → 200. Order-independent,
        // so it's deterministic under concurrency.
        MockURLProtocolHandler.responder = { req in
            if req.url?.path.hasSuffix("/auth/refresh") == true {
                return .init(json: #"{"user":{"accessToken":"FRESH"},"refreshToken":"R2"}"#)
            }
            let bearer = req.value(forHTTPHeaderField: "Authorization")
            return bearer == "Bearer FRESH"
                ? .init(json: #"{"ok":true}"#, statusCode: 200)
                : .init(json: "{}", statusCode: 401)
        }

        func fire() async throws -> Int {
            var req = URLRequest(url: URL(string: "https://abs.example.com/api/libraries")!)
            req.httpMethod = "GET"
            return try await auth.authorizedData(for: req).1.statusCode
        }

        async let a = fire()
        async let b = fire()
        let (ra, rb) = try await (a, b)

        XCTAssertEqual(ra, 200)
        XCTAssertEqual(rb, 200)
        XCTAssertNotNil(stored["k"], "no forced logout — tokens must survive")
        XCTAssertEqual(stored["k"]?.accessToken, "FRESH")
        XCTAssertEqual(stored["k"]?.refreshToken, "R2")

        let refreshCount = MockURLProtocolHandler.capturedRequests
            .filter { $0.url?.path.hasSuffix("/auth/refresh") == true }.count
        XCTAssertEqual(refreshCount, 1, "concurrent 401s must trigger exactly one refresh")
    }
}
