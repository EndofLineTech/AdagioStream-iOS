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
}
