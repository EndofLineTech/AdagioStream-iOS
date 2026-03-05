import XCTest
@testable import AdagioStream

final class DebugLoggerTests: XCTestCase {
    func testRedactsXCStreamURL() {
        let input = #"play() channel="CNN" url=https://tv.example.com:8080/live/myuser/mypass/12345.ts"#
        let result = DebugLogger.redactXtreamCodesCredentials(input)
        XCTAssertFalse(result.contains("tv.example.com"))
        XCTAssertFalse(result.contains("myuser"))
        XCTAssertFalse(result.contains("mypass"))
        XCTAssertTrue(result.contains("12345.ts"))
    }

    func testRedactsXCApiURL() {
        let input = "fetching https://tv.example.com/player_api.php?username=admin&password=secret&action=get_live"
        let result = DebugLogger.redactXtreamCodesCredentials(input)
        XCTAssertFalse(result.contains("tv.example.com"))
        XCTAssertFalse(result.contains("admin"))
        XCTAssertFalse(result.contains("secret"))
        XCTAssertTrue(result.contains("action=get_live"))
    }

    func testDoesNotRedactNonXCURLs() {
        let input = "fetching https://cdn.example.com/images/logo.png"
        let result = DebugLogger.redactXtreamCodesCredentials(input)
        XCTAssertEqual(input, result)
    }
}
