import XCTest
@testable import AdagioStream

final class DebugLoggerTests: XCTestCase {
    func testRedactsXCStreamURL() {
        let input = #"play() channel="CNN" url=https://tv.example.com:8080/live/myuser/mypass/12345.ts"#
        let result = DebugLogger.redactCredentials(input)
        XCTAssertFalse(result.contains("tv.example.com"))
        XCTAssertFalse(result.contains("myuser"))
        XCTAssertFalse(result.contains("mypass"))
        XCTAssertTrue(result.contains("12345.ts"))
    }

    func testRedactsXCApiURL() {
        let input = "fetching https://tv.example.com/player_api.php?username=admin&password=secret&action=get_live"
        let result = DebugLogger.redactCredentials(input)
        XCTAssertFalse(result.contains("tv.example.com"))
        XCTAssertFalse(result.contains("admin"))
        XCTAssertFalse(result.contains("secret"))
        XCTAssertTrue(result.contains("action=get_live"))
    }

    func testDoesNotRedactNonXCURLs() {
        let input = "fetching https://cdn.example.com/images/logo.png"
        let result = DebugLogger.redactCredentials(input)
        XCTAssertEqual(input, result)
    }

    func testRedactsSubsonicQueryParams() {
        // Subsonic API URL with token auth: u= username, t= token, s= salt
        let tokenInput = "https://music.example.com/rest/stream?u=alice&t=abc123&s=saltydog&id=42&v=1.16.1&c=AdagioStream"
        let tokenResult = DebugLogger.redactCredentials(tokenInput)
        XCTAssertFalse(tokenResult.contains("alice"), "u= (username) must be redacted")
        XCTAssertFalse(tokenResult.contains("abc123"), "t= (token) must be redacted")
        XCTAssertFalse(tokenResult.contains("saltydog"), "s= (salt) must be redacted")
        // Non-sensitive params must survive
        XCTAssertTrue(tokenResult.contains("id=42"))
        XCTAssertTrue(tokenResult.contains("v=1.16.1"))
        XCTAssertTrue(tokenResult.contains("c=AdagioStream"))
    }

    func testRedactsSubsonicLegacyPasswordParam() {
        // Subsonic legacy auth: p= plain/hex password
        let legacyInput = "https://music.example.com/rest/ping?u=bob&p=enc:68656c6c6f&v=1.16.1&c=AdagioStream"
        let legacyResult = DebugLogger.redactCredentials(legacyInput)
        XCTAssertFalse(legacyResult.contains("bob"), "u= must be redacted")
        XCTAssertFalse(legacyResult.contains("68656c6c6f"), "p= (legacy password) must be redacted")
        XCTAssertTrue(legacyResult.contains("v=1.16.1"))
        XCTAssertTrue(legacyResult.contains("c=AdagioStream"))
    }
}
