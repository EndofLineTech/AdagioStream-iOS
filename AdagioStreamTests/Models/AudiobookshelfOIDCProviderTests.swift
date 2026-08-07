import XCTest
@testable import AdagioStream

// wv4.3 — token-only ABS provider model: empty username+password marks an
// OIDC/SSO provider; password-authed providers are unaffected; the case still
// Codable round-trips.

final class AudiobookshelfOIDCProviderTests: XCTestCase {

    func testEmptyCredsMarkOIDC() {
        let oidc = Provider.ProviderType.audiobookshelf(
            host: URL(string: "https://abs.example.com")!, username: "", password: ""
        )
        XCTAssertTrue(oidc.isAudiobookshelfOIDC)
    }

    func testPasswordAuthedIsNotOIDC() {
        let pw = Provider.ProviderType.audiobookshelf(
            host: URL(string: "https://abs.example.com")!, username: "alice", password: "sesame"
        )
        XCTAssertFalse(pw.isAudiobookshelfOIDC)
    }

    func testNonABSTypesAreNotOIDC() {
        let subsonic = Provider.ProviderType.subsonic(
            host: URL(string: "https://nav.example.com")!, username: "", password: ""
        )
        XCTAssertFalse(subsonic.isAudiobookshelfOIDC)
        let m3u = Provider.ProviderType.m3u(url: URL(string: "https://x/y.m3u")!, epgURL: nil)
        XCTAssertFalse(m3u.isAudiobookshelfOIDC)
    }

    func testOIDCProviderCodableRoundTrip() throws {
        let provider = Provider(
            name: "Bookshelf SSO",
            type: .audiobookshelf(host: URL(string: "https://abs.example.com")!, username: "", password: "")
        )
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        XCTAssertEqual(decoded.name, "Bookshelf SSO")
        XCTAssertTrue(decoded.type.isAudiobookshelfOIDC)
        guard case .audiobookshelf(let host, let user, let pass) = decoded.type else {
            return XCTFail("expected audiobookshelf case")
        }
        XCTAssertEqual(host.absoluteString, "https://abs.example.com")
        XCTAssertTrue(user.isEmpty)
        XCTAssertTrue(pass.isEmpty)
    }
}
