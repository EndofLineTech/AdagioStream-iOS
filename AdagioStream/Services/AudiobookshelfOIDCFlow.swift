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

    /// base64url per RFC 4648 §5: base64 with `+`→`-`, `/`→`_`, padding stripped.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Shared-cookie session

    /// One `URLSession` with an isolated, ephemeral cookie store shared across
    /// `authorizationURL` and `exchange`. ABS sets an `auth_method` cookie in the
    /// first call that the callback needs; without a shared jar the exchange gets
    /// "invalid state"/session errors. Ephemeral so these cookies never touch the
    /// app's default cookie storage.
    public static func makeFlowSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }

    // MARK: - Step 1: authorization URL

    /// `GET /auth/openid?code_challenge=&code_challenge_method=S256&redirect_uri=
    /// &client_id=&response_type=code` → the IdP authorization URL to open in the
    /// browser. ABS stores our `redirect_uri` keyed by `state` and substitutes
    /// its own `/auth/openid/mobile-redirect` toward the IdP. Pass the shared
    /// `session` from `makeFlowSession()`.
    public static func authorizationURL(host: URL, challenge: String, session: URLSession) async throws -> URL {
        guard let url = AudiobookshelfURL.resolve(host: host, path: "/auth/openid", query: [
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "response_type": "code",
        ]) else { throw OIDCError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OIDCError.network(error)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OIDCError.discoveryFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // Prefer the JSON body; a `Location`-style redirect may already have been
        // followed by URLSession, in which case the final URL is the IdP URL.
        if let raw = decodeAuthURL(from: data), let authURL = URL(string: raw) {
            return authURL
        }
        if let finalURL = response.url, finalURL != url { return finalURL }
        throw OIDCError.authURLMissing
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

        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OIDCError.network(error)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OIDCError.discoveryFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
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
