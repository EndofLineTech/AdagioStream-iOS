import XCTest
@testable import AdagioStream

final class ExtensionsTests: XCTestCase {

    // MARK: - String.extractAttribute

    func testExtractAttributeFindsQuotedValue() {
        let line = #"#EXTINF:-1 tvg-id="channel1" tvg-name="My Channel" group-title="News",Display Name"#
        XCTAssertEqual(line.extractAttribute("tvg-id"), "channel1")
        XCTAssertEqual(line.extractAttribute("tvg-name"), "My Channel")
        XCTAssertEqual(line.extractAttribute("group-title"), "News")
    }

    func testExtractAttributeReturnsNilForMissingKey() {
        let line = #"#EXTINF:-1 tvg-id="channel1",Channel"#
        XCTAssertNil(line.extractAttribute("tvg-name"))
        XCTAssertNil(line.extractAttribute("tvg-logo"))
    }

    func testExtractAttributeHandlesEmptyValue() {
        let line = #"#EXTINF:-1 tvg-id="" tvg-name="Test",Channel"#
        // Empty quoted values are treated as missing (nil)
        XCTAssertNil(line.extractAttribute("tvg-id"))
    }

    // MARK: - URL.xtreamCodesURL

    func testXtreamCodesURLWithAction() {
        let base = URL(string: "http://example.com")!
        let url = base.xtreamCodesURL(username: "user", password: "pass", action: "get_live_streams")

        XCTAssertNotNil(url)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/player_api.php")

        let queryDict = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(queryDict["username"], "user")
        XCTAssertEqual(queryDict["password"], "pass")
        XCTAssertEqual(queryDict["action"], "get_live_streams")
    }

    func testXtreamCodesURLOmitsActionWhenEmpty() {
        let base = URL(string: "http://example.com")!
        let url = base.xtreamCodesURL(username: "user", password: "pass", action: "")

        XCTAssertNotNil(url)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let queryNames = components.queryItems!.map(\.name)
        XCTAssertFalse(queryNames.contains("action"))
    }

    func testXtreamCodesURLWithExtraParams() {
        let base = URL(string: "http://example.com")!
        let url = base.xtreamCodesURL(
            username: "user",
            password: "pass",
            action: "get_live_streams",
            params: ["category_id": "5"]
        )

        XCTAssertNotNil(url)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let queryDict = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(queryDict["category_id"], "5")
    }

    // MARK: - Int.durationString

    func testDurationStringZero() {
        XCTAssertEqual(0.durationString, "0:00")
    }

    func testDurationStringUnderAnHour() {
        XCTAssertEqual(90.durationString, "1:30")
    }

    func testDurationStringRollsOverAtAnHour() {
        // beads_mobilemusic-t96.2: the buggy SwiftUI copies rendered "125:30"
        // for a track over an hour instead of rolling to h:mm:ss.
        XCTAssertEqual(7530.durationString, "2:05:30")
        XCTAssertEqual(3600.durationString, "1:00:00")
    }

    // MARK: - URL.redactedForLog

    func testRedactedForLogRedactsXtreamPathCredentials() {
        let url = URL(string: "http://example.com/live/alice/sesame/123.ts")!
        XCTAssertEqual(url.redactedForLog, "http://example.com/live/***/***/123.ts")
    }

    func testRedactedForLogRedactsXtreamQueryCredentials() {
        let url = URL(string: "http://example.com/player_api.php?username=alice&password=sesame&action=get_live_streams")!
        let redacted = url.redactedForLog
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("sesame"))
        XCTAssertTrue(redacted.contains("username=%2A%2A%2A") || redacted.contains("username=***"))
    }

    func testRedactedForLogRedactsSubsonicQueryCredentials() {
        // beads_mobilemusic-t96.6: Subsonic auth uses u/p/t/s query params
        // instead of Xtream's username/password.
        let url = URL(string: "http://navidrome.example.com/rest/ping.view?u=alice&p=sesame&t=abcdef&s=salt123&v=1.16.1&c=AdagioStream&f=json")!
        let redacted = url.redactedForLog
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("sesame"))
        XCTAssertFalse(redacted.contains("abcdef"))
        XCTAssertFalse(redacted.contains("salt123"))
        // Non-credential params survive untouched.
        XCTAssertTrue(redacted.contains("v=1.16.1"))
        XCTAssertTrue(redacted.contains("c=AdagioStream"))
    }
}
