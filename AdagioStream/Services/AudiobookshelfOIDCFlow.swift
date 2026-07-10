import Foundation
import CryptoKit

/// PKCE generation and the two server GETs of the ABS OpenID flow. tvOS-safe:
/// CryptoKit is cross-platform and no `AuthenticationServices` import lives here
/// (the browser session UI is iOS-only, under `Views/`).
///
/// SECURITY: never log the verifier, the code, the tokens, or the full callback
/// URL — those are secrets. Callers must persist the returned tokens via the
/// existing `AudiobookshelfAuth` Keychain storage.
extension AudiobookshelfOIDC {

    // MARK: - PKCE

    /// A PKCE pair. `verifier` is the secret; `challenge` = base64url(SHA256(verifier)).
    public struct PKCE: Equatable {
        public let verifier: String
        public let challenge: String
    }

    /// Generates a fresh PKCE pair. 32 random bytes → 43-char base64url verifier
    /// (within RFC 7636's 43–128 range). Challenge is base64url(SHA256(verifier)).
    public static func makePKCE() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    /// A random CSRF `state`: 32 random bytes as base64url. The client generates
    /// it, sends it to `/auth/openid`, and MUST compare it against the value the
    /// browser callback returns before exchanging the code — otherwise a crafted
    /// `adagiostream://oauth?code=…` on the app-wide scheme could inject an
    /// attacker's authorization code. PKCE alone does not cover this.
    public static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// base64url per RFC 4648 §5: base64 with `+`→`-`, `/`→`_`, padding stripped.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Shared-cookie session

    /// URLSession delegate that cancels every HTTP redirect (returns the 3xx
    /// response as-is instead of following it). The official audiobookshelf-app
    /// client sets `redirect: 'manual'` on `/auth/openid` and reads only the
    /// `Location` header — following the 302 to Google (and downloading ~900KB of
    /// sign-in HTML) is the one divergence we saw against the popup-500. This
    /// makes the flow session match the official client. Foundation-only, so it
    /// stays tvOS-safe.
    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // cancel: return the 3xx response, don't follow.
        }
    }

    /// One `URLSession` with an isolated, ephemeral cookie store shared across
    /// `authorizationURL` and `exchange`. ABS sets an `auth_method` cookie in the
    /// first call that the callback needs; without a shared jar the exchange gets
    /// "invalid state"/session errors. Ephemeral so these cookies never touch the
    /// app's default cookie storage. The `NoRedirectDelegate` stops us following
    /// `/auth/openid`'s 302 to the IdP so we read the `Location` header instead.
    public static func makeFlowSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: - Step 1: authorization URL

    /// `GET /auth/openid?code_challenge=&code_challenge_method=S256&redirect_uri=
    /// &client_id=&response_type=code` → the IdP authorization URL to open in the
    /// browser. ABS stores our `redirect_uri` keyed by `state` and substitutes
    /// its own `/auth/openid/mobile-redirect` toward the IdP. Pass the shared
    /// `session` from `makeFlowSession()` and the `state` from `makeState()`;
    /// the caller MUST validate the callback's `state` against it before exchange.
    public static func authorizationURL(host: URL, challenge: String, state: String, session: URLSession) async throws -> URL {
        guard let url = AudiobookshelfURL.resolve(host: host, path: "/auth/openid", query: [
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "response_type": "code",
            "state": state,
        ]) else { throw OIDCError.invalidURL }

        // TEMP-OIDC-DEBUG zq2: log the EXACT /auth/openid request we send (all
        // query params, incl. the encoded redirect_uri/code_challenge/state).
        DebugLogger.shared.log("[OIDC] SENSITIVE DEBUG BUILD — logs OAuth material; do not distribute", category: .providers)
        DebugLogger.shared.log("[OIDC] /auth/openid request URL: \(url.absoluteString)", category: .providers)

        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // TEMP-OIDC-DEBUG zq2
            DebugLogger.shared.log("[OIDC] /auth/openid transport error: \(error)", category: .providers)
            throw OIDCError.network(error)
        }
        let http0 = response as? HTTPURLResponse
        let startStatus = http0?.statusCode ?? -1
        let location = http0?.value(forHTTPHeaderField: "Location")
        // TEMP-OIDC-DEBUG zq2: NEW behavior — we no longer FOLLOW the 302 to the
        // IdP; the flow session's NoRedirectDelegate cancels the redirect, so we
        // read the `Location` header of the 3xx (matching the official client).
        // This line shows the status + extracted Location so the next log proves
        // we read Location instead of downloading Google's sign-in HTML.
        DebugLogger.shared.log("[OIDC] /auth/openid response status=\(startStatus) location=\(location ?? "nil") bodyLen=\(data.count)", category: .providers)

        // Cancelling the 302 (NoRedirectDelegate) means URLSession does NOT
        // auto-store the express-session Set-Cookie (e.g. connect.sid) that ABS
        // sets on /auth/openid. Capture it explicitly into the flow session's
        // cookie jar so the later /auth/openid/callback sends it — without it ABS
        // rejects the callback with 400 "No session". Do this on any 3xx OR 2xx.
        if let http = http0, (200...399).contains(startStatus) {
            captureSessionCookies(from: http, requestURL: url, into: session.configuration.httpCookieStorage)
        }

        // The official audiobookshelf-app treats ANY 3xx from /auth/openid as the
        // success case and reads the IdP URL from the Location header.
        if (300...399).contains(startStatus) {
            if let loc = location, let authURL = URL(string: loc) {
                DebugLogger.shared.log("[OIDC] auth URL from Location header: \(authURL.absoluteString)", category: .providers) // TEMP-OIDC-DEBUG zq2
                return authURL
            }
            // 3xx with no usable Location — fall through to body/error below.
        }

        // Defensive fallback: a non-3xx 2xx server that returns the auth URL in a
        // JSON body (some deployments). Keep this path so we don't regress those.
        guard let http = response as? HTTPURLResponse,
              (200...399).contains(http.statusCode) else {
            // TEMP-OIDC-DEBUG zq2
            DebugLogger.shared.log("[OIDC] /auth/openid FAILED status=\(startStatus) body=\(String(data: data, encoding: .utf8)?.prefix(500) ?? "")", category: .providers)
            throw OIDCError.requestFailed(
                step: "sign-in start",
                statusCode: startStatus,
                detail: safeErrorDetail(from: data)
            )
        }
        if let raw = decodeAuthURL(from: data), let authURL = URL(string: raw) {
            DebugLogger.shared.log("[OIDC] auth URL from body: \(authURL.absoluteString)", category: .providers) // TEMP-OIDC-DEBUG zq2
            return authURL
        }
        throw OIDCError.authURLMissing
    }

    /// Parses `Set-Cookie` from a `/auth/openid` response and stores the cookies
    /// into `storage` for the request URL, so the same flow session sends them on
    /// `/auth/openid/callback`. Pure enough to unit-test (no async round-trip).
    /// SECURITY: logs cookie NAMES + domain + path only — never the value.
    @discardableResult
    static func captureSessionCookies(from http: HTTPURLResponse, requestURL: URL, into storage: HTTPCookieStorage?) -> [HTTPCookie] {
        guard let headers = http.allHeaderFields as? [String: String] else { return [] }
        let cookieURL = http.url ?? requestURL
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: cookieURL)
        if cookies.isEmpty {
            DebugLogger.shared.log("[OIDC] /auth/openid Set-Cookie captured: none", category: .providers) // TEMP-OIDC-DEBUG zq2
            return []
        }
        storage?.setCookies(cookies, for: cookieURL, mainDocumentURL: nil)
        // TEMP-OIDC-DEBUG zq2: NAMES + domain + path only — NEVER the value.
        let summary = cookies.map { "\($0.name)@\($0.domain)\($0.path)" }.joined(separator: ",")
        DebugLogger.shared.log("[OIDC] /auth/openid Set-Cookie captured: [\(summary)]", category: .providers)
        return cookies
    }

    struct AuthURLResponse: Decodable {
        let authorizationUrl: String?
        let authorization_url: String?
        let url: String?
    }

    /// Extracts the authorization URL string from the `/auth/openid` body — JSON
    /// object with one of several key spellings, or a bare URL string. Pure.
    static func decodeAuthURL(from data: Data) -> String? {
        if let obj = try? JSONDecoder().decode(AuthURLResponse.self, from: data),
           let raw = obj.authorizationUrl ?? obj.authorization_url ?? obj.url {
            return raw
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("http") {
            return raw
        }
        return nil
    }

    // MARK: - Callback parsing + CSRF validation

    /// A validated `adagiostream://oauth` callback: the code, plus the state
    /// already confirmed to match the request's state.
    public struct Callback: Equatable {
        public let code: String
        public let state: String
    }

    /// Parses a callback URL and enforces the CSRF `state` match. Returns nil on
    /// a missing param OR a mismatched state — callers must NOT exchange on nil.
    /// Pure — unit-tested; keeps the security check out of the untestable
    /// ASWebAuthenticationSession path.
    static func validatedCallback(_ url: URL, expectedState: String) -> Callback? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState else {
            return nil
        }
        return Callback(code: code, state: state)
    }

    // MARK: - Step 3: token exchange

    /// `GET /auth/openid/callback?state=&code=&code_verifier=` → the same
    /// `{ user: { accessToken, refreshToken } }` shape as password login. MUST
    /// use the SAME `session` as `authorizationURL(...)` so the `auth_method`
    /// cookie set earlier is sent.
    public static func exchange(
        host: URL,
        state: String,
        code: String,
        verifier: String,
        session: URLSession
    ) async throws -> AudiobookshelfAuth.Tokens {
        guard let url = AudiobookshelfURL.resolve(host: host, path: "/auth/openid/callback", query: [
            "state": state,
            "code": code,
            "code_verifier": verifier,
        ]) else { throw OIDCError.invalidURL }

        // TEMP-OIDC-DEBUG zq2: log the EXACT /auth/openid/callback URL we build
        // (encoded code/code_verifier/state). Reaching here means the browser
        // DID hand us a callback — if the popup 500s, this line never appears.
        DebugLogger.shared.log("[OIDC] /auth/openid/callback request URL: \(url.absoluteString)", category: .providers)

        // TEMP-OIDC-DEBUG zq2: which cookies the flow session WILL send for the
        // callback — proves whether the /auth/openid session cookie is present +
        // path-matched. NAMES + domain + path only, NEVER the value.
        let willSend = session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        let willSendSummary = willSend.map { "\($0.name)@\($0.domain)\($0.path)" }.joined(separator: ",")
        DebugLogger.shared.log("[OIDC] /auth/openid/callback will send cookies: [\(willSendSummary)]", category: .providers)

        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // TEMP-OIDC-DEBUG zq2
            DebugLogger.shared.log("[OIDC] /auth/openid/callback transport error: \(error)", category: .providers)
            throw OIDCError.network(error)
        }
        // TEMP-OIDC-DEBUG zq2: status + body ONLY on failure. Do NOT log a
        // success body — it carries access/refresh tokens (reusable secrets).
        let exStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // TEMP-OIDC-DEBUG zq2
            DebugLogger.shared.log("[OIDC] /auth/openid/callback FAILED status=\(exStatus) body=\(String(data: data, encoding: .utf8)?.prefix(500) ?? "")", category: .providers)
            throw OIDCError.requestFailed(
                step: "token exchange",
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                detail: safeErrorDetail(from: data)
            )
        }
        DebugLogger.shared.log("[OIDC] /auth/openid/callback status=\(exStatus) OK (token body redacted)", category: .providers) // TEMP-OIDC-DEBUG zq2
        return try parseTokens(from: data)
    }

    /// Extracts the token pair from a `/auth/openid/callback` body. Reuses the
    /// login/refresh DTO shape (tokens under `user`, refresh possibly top-level).
    /// Pure — unit-tested.
    static func parseTokens(from data: Data) throws -> AudiobookshelfAuth.Tokens {
        guard let payload = try? JSONDecoder().decode(LoginResponse.self, from: data),
              let access = payload.user?.accessToken,
              let refresh = payload.refreshToken ?? payload.user?.refreshToken else {
            throw OIDCError.malformedResponse
        }
        return AudiobookshelfAuth.Tokens(accessToken: access, refreshToken: refresh)
    }
}
