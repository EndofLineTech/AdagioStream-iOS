import XCTest
@testable import AdagioStream

/// Truth-table coverage for beads_mobilemusic-uxb.3's shared validation
/// decision function — the pure logic behind AddProviderView, WelcomeSetupView,
/// and AddManualEntryView's inline field captions.
final class ProviderFormValidationTests: XCTestCase {

    // MARK: - validate(kind:name:host:username:password:)

    func testAllFieldsValidReturnsNoErrors() {
        let result = ProviderFormValidation.validate(
            kind: .xtreamCodes,
            name: "My Server",
            host: "https://example.com",
            username: "user",
            password: "pass"
        )
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.name)
        XCTAssertNil(result.host)
        XCTAssertNil(result.username)
        XCTAssertNil(result.password)
    }

    func testEmptyNameIsRejected() {
        let result = ProviderFormValidation.validate(
            kind: .m3u, name: "", host: "https://example.com/list.m3u", username: "", password: ""
        )
        XCTAssertEqual(result.name, "Name is required")
        XCTAssertFalse(result.isValid)
    }

    func testWhitespaceOnlyNameIsRejected() {
        let result = ProviderFormValidation.validate(
            kind: .m3u, name: "   ", host: "https://example.com/list.m3u", username: "", password: ""
        )
        XCTAssertEqual(result.name, "Name is required")
    }

    func testEmptyHostIsRejected() {
        let result = ProviderFormValidation.validate(kind: .m3u, name: "X", host: "", username: "", password: "")
        XCTAssertEqual(result.host, "Enter a valid URL (http/https)")
    }

    func testNonHTTPSchemeIsRejected() {
        let result = ProviderFormValidation.validate(
            kind: .m3u, name: "X", host: "ftp://example.com/list.m3u", username: "", password: ""
        )
        XCTAssertEqual(result.host, "Enter a valid URL (http/https)")
    }

    func testHTTPSchemeIsAccepted() {
        let result = ProviderFormValidation.validate(
            kind: .m3u, name: "X", host: "http://example.com/list.m3u", username: "", password: ""
        )
        XCTAssertNil(result.host)
    }

    func testM3UDoesNotRequireUsernameOrPassword() {
        let result = ProviderFormValidation.validate(
            kind: .m3u, name: "X", host: "https://example.com/list.m3u", username: "", password: ""
        )
        XCTAssertTrue(result.isValid)
    }

    func testM3UWithGarbageURLIsInvalid() {
        // Deliberately malformed (no scheme at all) — URL(string:) still parses many
        // strings, so this exercises the "no scheme" branch of isValidURL.
        let result = ProviderFormValidation.validate(
            kind: .m3u, name: "X", host: "not a url", username: "", password: ""
        )
        XCTAssertNotNil(result.host)
    }

    func testXtreamCodesRequiresUsernameAndPassword() {
        let result = ProviderFormValidation.validate(
            kind: .xtreamCodes, name: "X", host: "https://example.com", username: "", password: ""
        )
        XCTAssertEqual(result.username, "Username is required")
        XCTAssertEqual(result.password, "Password is required")
        XCTAssertFalse(result.isValid)
    }

    func testSubsonicRequiresUsernameAndPassword() {
        let result = ProviderFormValidation.validate(
            kind: .subsonic, name: "X", host: "https://example.com", username: "u", password: ""
        )
        XCTAssertNil(result.username)
        XCTAssertEqual(result.password, "Password is required")
    }

    func testAudiobookshelfRequiresUsernameAndPassword() {
        let result = ProviderFormValidation.validate(
            kind: .audiobookshelf, name: "X", host: "https://example.com", username: "", password: "p"
        )
        XCTAssertEqual(result.username, "Username is required")
        XCTAssertNil(result.password)
    }

    func testEverythingMissingReportsEveryField() {
        let result = ProviderFormValidation.validate(
            kind: .xtreamCodes, name: "", host: "", username: "", password: ""
        )
        XCTAssertEqual(result.name, "Name is required")
        XCTAssertEqual(result.host, "Enter a valid URL (http/https)")
        XCTAssertEqual(result.username, "Username is required")
        XCTAssertEqual(result.password, "Password is required")
    }

    // MARK: - validateManualEntry(name:url:hasGroup:)

    func testManualEntryAllValidReturnsNoErrors() {
        let result = ProviderFormValidation.validateManualEntry(
            name: "My Stream", url: "https://example.com/stream.m3u8", hasGroup: true
        )
        XCTAssertTrue(result.isValid)
    }

    func testManualEntryEmptyNameIsRejected() {
        let result = ProviderFormValidation.validateManualEntry(name: "", url: "https://x.com/s", hasGroup: true)
        XCTAssertEqual(result.name, "Name is required")
    }

    func testManualEntryEmptyURLIsRejected() {
        let result = ProviderFormValidation.validateManualEntry(name: "X", url: "", hasGroup: true)
        XCTAssertEqual(result.url, "Stream URL is required")
    }

    func testManualEntryDisallowedSchemeIsRejected() {
        let result = ProviderFormValidation.validateManualEntry(name: "X", url: "ftp://x.com/s", hasGroup: true)
        XCTAssertEqual(result.url, "Enter a valid URL (http/https/rtsp/rtmp/mms)")
    }

    func testManualEntryAcceptsRTSPAndRTMPAndMMS() {
        for scheme in ["rtsp", "rtmp", "mms", "http", "https"] {
            let result = ProviderFormValidation.validateManualEntry(
                name: "X", url: "\(scheme)://x.com/s", hasGroup: true
            )
            XCTAssertNil(result.url, "scheme \(scheme) should be accepted")
        }
    }

    func testManualEntryMissingGroupIsRejected() {
        let result = ProviderFormValidation.validateManualEntry(name: "X", url: "https://x.com/s", hasGroup: false)
        XCTAssertEqual(result.group, "Choose a group")
    }

    // MARK: - isValidURL

    func testIsValidURLRejectsEmptyString() {
        XCTAssertFalse(ProviderFormValidation.isValidURL("", allowedSchemes: ["http", "https"]))
    }
}
