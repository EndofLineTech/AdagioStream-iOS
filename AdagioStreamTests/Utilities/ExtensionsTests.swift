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
}
