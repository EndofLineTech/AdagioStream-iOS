import XCTest
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
}
