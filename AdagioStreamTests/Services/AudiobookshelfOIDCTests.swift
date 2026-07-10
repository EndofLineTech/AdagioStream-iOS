import XCTest
import CryptoKit
@testable import AdagioStream

// wv4.1 — /status discovery parsing (openid availability + button label).

final class AudiobookshelfOIDCTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocolHandler.reset()
    }

    override func tearDown() {
        MockURLProtocolHandler.reset()
        super.tearDown()
    }

    // MARK: - Discovery parsing

    func testDiscoveryDetectsOpenIDAndUsesButtonLabel() async throws {
        MockURLProtocolHandler.responseQueue = [.init(json: """
        {
          "isInit": true,
          "authMethods": ["local", "openid"],
          "authFormData": {
            "authOpenIDButtonText": "Sign in with Google",
            "authOpenIDAutoLaunch": true
          }
        }
        """)]
        let d = try await AudiobookshelfOIDC.discover(
            host: URL(string: "https://abs.example.com")!,
            session: MockURLProtocolHandler.makeSession()
        )
        XCTAssertTrue(d.supportsOpenID)
        XCTAssertEqual(d.buttonText, "Sign in with Google")
        XCTAssertTrue(d.autoLaunch)
        XCTAssertTrue(d.isInit)
    }

    // Regression for bug 1e4: the user's real ABS 2.35.1 /status payload
    // (authMethods ["local","openid"], button "Login with Google") must yield
    // supportsOpenID:true + supportsLocal:true so the URL-first flow reveals
    // BOTH the SSO button and the password fields. Mocked — never hits the live
    // server. (The runtime bug was in the view's debounce, but this locks the
    // decode against the exact production shape so a decode regression can't
    // silently re-hide the button.)
    func testDiscoveryDecodesRealUserStatusPayload() async throws {
        MockURLProtocolHandler.responseQueue = [.init(json: """
        {
          "app": "audiobookshelf",
          "serverVersion": "2.35.1",
          "isInit": true,
          "language": "en-us",
          "authMethods": ["local", "openid"],
          "authFormData": {
            "authLoginCustomMessage": "",
            "authOpenIDButtonText": "Login with Google",
            "authOpenIDAutoLaunch": false
          }
        }
        """)]
        let d = try await AudiobookshelfOIDC.discover(
            host: URL(string: "https://bookshelf.endofline.tech")!,
            session: MockURLProtocolHandler.makeSession()
        )
        XCTAssertTrue(d.supportsOpenID, "openid must be detected from the real payload")
        XCTAssertTrue(d.supportsLocal, "local must be detected so password fields show")
        XCTAssertEqual(d.buttonText, "Login with Google")
        XCTAssertFalse(d.autoLaunch)
        XCTAssertTrue(d.isInit)
    }

    func testDiscoveryReportsLocalAbsentWhenOnlyOpenID() {
        let status = AudiobookshelfOIDC.StatusResponse(
            isInit: true,
            authMethods: ["openid"],
            authFormData: nil
        )
        let d = AudiobookshelfOIDC.discovery(from: status)
        XCTAssertTrue(d.supportsOpenID)
        XCTAssertFalse(d.supportsLocal, "openid-only server should not advertise local auth")
    }

    // Lockout floor (review #1): a server offering only an unrecognized method
    // (e.g. ["ldap"]) has neither local nor openid. The add-provider form must
    // still expose the password fields (SSO isn't the offered path), so the user
    // isn't locked out. This mirrors AddProviderView.absShowsPasswordFields
    // (supportsLocal || !supportsOpenID) at the discovery layer.
    func testDiscoveryUnknownMethodShowsPasswordFloor() {
        let status = AudiobookshelfOIDC.StatusResponse(
            isInit: true,
            authMethods: ["ldap"],
            authFormData: nil
        )
        let d = AudiobookshelfOIDC.discovery(from: status)
        XCTAssertFalse(d.supportsOpenID)
        XCTAssertFalse(d.supportsLocal)
        // The view floor: show password whenever SSO isn't offered.
        XCTAssertTrue(d.supportsLocal || !d.supportsOpenID,
                      "unknown-only auth method must still expose the password path")
    }

    func testDiscoveryOpenIDAbsentWhenNotInAuthMethods() async throws {
        MockURLProtocolHandler.responseQueue = [.init(json: """
        {"isInit": true, "authMethods": ["local"]}
        """)]
        let d = try await AudiobookshelfOIDC.discover(
            host: URL(string: "https://abs.example.com")!,
            session: MockURLProtocolHandler.makeSession()
        )
        XCTAssertFalse(d.supportsOpenID)
        // Falls back to the default label when the server omits it.
        XCTAssertEqual(d.buttonText, "Login with OpenID")
    }

    func testDiscoveryFallsBackToDefaultLabelWhenBlank() {
        let status = AudiobookshelfOIDC.StatusResponse(
            isInit: false,
            authMethods: ["openid"],
            authFormData: .init(authOpenIDButtonText: "", authOpenIDAutoLaunch: nil)
        )
        let d = AudiobookshelfOIDC.discovery(from: status)
        XCTAssertTrue(d.supportsOpenID)
        XCTAssertEqual(d.buttonText, "Login with OpenID")
        XCTAssertFalse(d.autoLaunch)
        XCTAssertFalse(d.isInit)
    }

    func testDiscoveryThrowsOnNon2xx() async {
        MockURLProtocolHandler.responseQueue = [.init(json: "{}", statusCode: 500)]
        do {
            _ = try await AudiobookshelfOIDC.discover(
                host: URL(string: "https://abs.example.com")!,
                session: MockURLProtocolHandler.makeSession()
            )
            XCTFail("expected discoveryFailed")
        } catch let AudiobookshelfOIDC.OIDCError.discoveryFailed(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - PKCE (wv4.2)

    func testPKCEVerifierLengthAndCharset() {
        let pkce = AudiobookshelfOIDC.makePKCE()
        // RFC 7636: 43–128 chars. 32 random bytes → 43 base64url chars.
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertLessThanOrEqual(pkce.verifier.count, 128)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "verifier must be base64url with no padding")
        XCTAssertTrue(pkce.challenge.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testPKCEChallengeIsBase64URLSha256OfVerifier() {
        let pkce = AudiobookshelfOIDC.makePKCE()
        let expected = AudiobookshelfOIDC.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8))))
        XCTAssertEqual(pkce.challenge, expected)
    }

    func testPKCEIsRandomPerCall() {
        XCTAssertNotEqual(AudiobookshelfOIDC.makePKCE().verifier,
                          AudiobookshelfOIDC.makePKCE().verifier)
    }

    func testBase64URLReplacesPlusSlashAndStripsPadding() {
        // 0xFB 0xFF → base64 "+/8=" → base64url "-_8".
        let out = AudiobookshelfOIDC.base64URL(Data([0xFB, 0xFF]))
        XCTAssertEqual(out, "-_8")
        XCTAssertFalse(out.contains("+"))
        XCTAssertFalse(out.contains("/"))
        XCTAssertFalse(out.contains("="))
    }

    // MARK: - Callback token parsing (wv4.2)

    func testParseTokensFromCallbackBody() throws {
        let json = """
        {"user": {"accessToken": "acc123", "refreshToken": "ref456", "token": "acc123"}}
        """
        let tokens = try AudiobookshelfOIDC.parseTokens(from: Data(json.utf8))
        XCTAssertEqual(tokens.accessToken, "acc123")
        XCTAssertEqual(tokens.refreshToken, "ref456")
    }

    func testParseTokensUsesTopLevelRefreshWhenUserOmitsIt() throws {
        let json = """
        {"user": {"accessToken": "acc"}, "refreshToken": "topref"}
        """
        let tokens = try AudiobookshelfOIDC.parseTokens(from: Data(json.utf8))
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertEqual(tokens.refreshToken, "topref")
    }

    func testParseTokensThrowsWhenAccessMissing() {
        let json = #"{"user": {"refreshToken": "r"}}"#
        XCTAssertThrowsError(try AudiobookshelfOIDC.parseTokens(from: Data(json.utf8)))
    }

    // MARK: - Authorization URL body decoding (wv4.2)

    func testDecodeAuthURLFromJSONObject() {
        let json = #"{"authorizationUrl": "https://accounts.google.com/o/oauth2/v2/auth?x=1"}"#
        XCTAssertEqual(AudiobookshelfOIDC.decodeAuthURL(from: Data(json.utf8)),
                       "https://accounts.google.com/o/oauth2/v2/auth?x=1")
    }

    func testDecodeAuthURLFromBareString() {
        let raw = "https://idp.example.com/authorize?state=abc"
        XCTAssertEqual(AudiobookshelfOIDC.decodeAuthURL(from: Data(raw.utf8)), raw)
    }

    // MARK: - CSRF state (security fix)

    func testStateIsRandomPerCall() {
        XCTAssertNotEqual(AudiobookshelfOIDC.makeState(), AudiobookshelfOIDC.makeState())
        // 32 bytes → 43-char base64url, no padding.
        XCTAssertEqual(AudiobookshelfOIDC.makeState().count, 43)
    }

    func testAuthorizationURLIncludesState() async throws {
        MockURLProtocolHandler.responseQueue = [.init(json:
            #"{"authorizationUrl": "https://idp.example.com/authorize"}"#)]
        _ = try await AudiobookshelfOIDC.authorizationURL(
            host: URL(string: "https://abs.example.com")!,
            challenge: "chal",
            state: "STATE123",
            session: MockURLProtocolHandler.makeSession()
        )
        let sent = MockURLProtocolHandler.capturedRequests.first?.url
        let items = URLComponents(url: sent!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "state" })?.value, "STATE123")
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
    }

    // beads_mobilemusic-zq2: match the official audiobookshelf-app client — a 3xx
    // from /auth/openid is the success case and the IdP URL comes from the
    // `Location` header, NOT from following the redirect to Google.
    func testAuthorizationURLReadsLocationHeaderOn3xx() async throws {
        MockURLProtocolHandler.responseQueue = [.init(
            data: Data(),
            statusCode: 302,
            headers: ["Location": "https://idp.example.com/authorize?foo=bar"]
        )]
        let (authURL, _) = try await AudiobookshelfOIDC.authorizationURL(
            host: URL(string: "https://abs.example.com")!,
            challenge: "chal",
            state: "STATE123",
            session: MockURLProtocolHandler.makeSession()
        )
        XCTAssertEqual(authURL.absoluteString, "https://idp.example.com/authorize?foo=bar")
    }

    // beads_mobilemusic-zq2: cookie-capture (captureSessionCookies) verified
    // manually — a synchronous helper test wedged the sim harness on the cold
    // simulator, so it's omitted per coordinator direction.
    // ponytail: cookie capture verified manually; async URLSession test hangs, skipped.

    // beads_mobilemusic-zq2: the Cookie header sent on /auth/openid/callback is
    // built from the cookies authorizationURL captured — a manual HTTPCookieStorage
    // won't hand them back via cookies(for:), so we attach them explicitly.
    // Fully synchronous (no async/URLSession) — the async path hangs the sim.
    func testCookieHeaderJoinsNameValuePairs() {
        let c1 = HTTPCookie(properties: [
            .domain: "abs.example.com", .path: "/", .name: "connect.sid", .value: "abc",
        ])!
        let c2 = HTTPCookie(properties: [
            .domain: "abs.example.com", .path: "/", .name: "auth_method", .value: "openid",
        ])!
        XCTAssertEqual(AudiobookshelfOIDC.cookieHeader(from: [c1, c2]),
                       "connect.sid=abc; auth_method=openid")
        XCTAssertEqual(AudiobookshelfOIDC.cookieHeader(from: []), "")
    }

    func testValidatedCallbackAcceptsMatchingState() {
        let url = URL(string: "adagiostream://oauth?code=abc&state=S1")!
        let cb = AudiobookshelfOIDC.validatedCallback(url, expectedState: "S1")
        XCTAssertEqual(cb, AudiobookshelfOIDC.Callback(code: "abc", state: "S1"))
    }

    func testValidatedCallbackRejectsMismatchedState() {
        // A crafted callback with an attacker's code but a foreign state.
        let url = URL(string: "adagiostream://oauth?code=attacker&state=WRONG")!
        XCTAssertNil(AudiobookshelfOIDC.validatedCallback(url, expectedState: "S1"),
                     "must reject (and thus not exchange) on state mismatch")
    }

    func testValidatedCallbackRejectsMissingCode() {
        let url = URL(string: "adagiostream://oauth?state=S1")!
        XCTAssertNil(AudiobookshelfOIDC.validatedCallback(url, expectedState: "S1"))
    }

    // MARK: - Code round-trip encoding (beads_mobilemusic-zq2)

    /// Decodes a query the way ABS's server (express/`qs`) does: a literal `+`
    /// becomes a SPACE, then the rest is percent-decoded. This is what actually
    /// happens to the `code` on the wire — Foundation's own decoder treats `+`
    /// literally and would hide the bug, so we model the server explicitly.
    private func serverDecodeQueryValue(_ raw: String) -> String {
        let plusToSpace = raw.replacingOccurrences(of: "+", with: " ")
        return plusToSpace.removingPercentEncoding ?? plusToSpace
    }

    /// Regression: a Google OIDC auth code often contains `+`, `/`, and `=`. The
    /// callback URL delivers it percent-encoded; `validatedCallback` decodes it
    /// once; `AudiobookshelfURL.resolve` must re-encode it so ABS's `+`→space
    /// decode reconstructs the EXACT code. Before the fix, `URLComponents`
    /// left `+` unescaped → ABS saw a space → `invalid_grant (Malformed auth
    /// code)` → HTTP 500.
    func testAuthCodeWithPlusSlashEqualsRoundTripsToServerIntact() {
        let realCode = "4/0AX4XfWh-abc/def=ghi+jkl"   // realistic Google code shape
        let realState = "st/ate=+val"

        // 1. Browser delivers the callback percent-encoded (as ABS's
        //    mobile-redirect does via encodeURIComponent).
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        let callbackURL = URL(string: "adagiostream://oauth?code=\(enc(realCode))&state=\(enc(realState))")!

        // 2. Extraction decodes once.
        guard let cb = AudiobookshelfOIDC.validatedCallback(callbackURL, expectedState: realState) else {
            return XCTFail("callback should validate")
        }
        XCTAssertEqual(cb.code, realCode, "extraction should decode the code exactly once")

        // 3. Build the exchange URL through the shared resolver.
        let exURL = AudiobookshelfURL.resolve(
            host: URL(string: "https://abs.example.com")!,
            path: "/auth/openid/callback",
            query: ["state": cb.state, "code": cb.code, "code_verifier": "verifierXYZ"]
        )!

        // 4. What the SERVER reconstructs must equal the ORIGINAL code/state.
        let comps = URLComponents(url: exURL, resolvingAgainstBaseURL: false)!
        let wireCode = comps.percentEncodedQueryItems!.first { $0.name == "code" }!.value!
        let wireState = comps.percentEncodedQueryItems!.first { $0.name == "state" }!.value!
        XCTAssertTrue(wireCode.contains("%2B"), "'+' MUST be percent-encoded on the wire, not left literal")
        XCTAssertEqual(serverDecodeQueryValue(wireCode), realCode,
                       "ABS's +→space decode must reconstruct the exact auth code")
        XCTAssertEqual(serverDecodeQueryValue(wireState), realState)
    }

    /// The subpath (reverse-proxy base path) must be preserved on ALL OIDC
    /// endpoints when the user enters a subpath host — else the flow hits the
    /// wrong routes (ymf.1). Covers discovery, auth-URL, and callback builders.
    func testSubpathHostPreservedOnAllOIDCEndpoints() {
        let host = URL(string: "https://abs.example.com/audiobookshelf")!
        for path in ["/status", "/auth/openid", "/auth/openid/callback"] {
            let url = AudiobookshelfURL.resolve(host: host, path: path)!
            XCTAssertEqual(url.path, "/audiobookshelf" + path,
                           "subpath must be preserved on \(path)")
        }
    }
}
