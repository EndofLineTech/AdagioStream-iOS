import XCTest
@testable import AdagioStream

/// Baseline characterization for `Provider` decoding and the simple list
/// operations that ProviderManager mediates. Smoke level — exercises the
/// model decode round-trip and the list-mutation surface that survives
/// extraction. Full ProviderManager integration coverage is out of scope
/// for Phase 0.
final class ProviderManagerTests: XCTestCase {

    func testProviderRoundTripsThroughJSON() throws {
        let original = Provider(
            id: UUID(),
            name: "Test Xtream",
            type: .xtreamCodes(
                host: URL(string: "https://example.com")!,
                username: "u",
                password: "p"
            ),
            isEnabled: true,
            stripStreamIDs: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
        XCTAssertEqual(decoded.stripStreamIDs, original.stripStreamIDs)
    }

    func testProviderListEncodeDecode() throws {
        let providers = [
            Provider(
                name: "M3U Provider",
                type: .m3u(url: URL(string: "https://example.com/list.m3u")!, epgURL: nil)
            ),
            Provider(
                name: "Xtream Provider",
                type: .xtreamCodes(
                    host: URL(string: "https://x.example.com")!,
                    username: "user",
                    password: "pass"
                )
            ),
        ]

        let data = try JSONEncoder().encode(providers)
        let decoded = try JSONDecoder().decode([Provider].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "M3U Provider")
        XCTAssertEqual(decoded[1].name, "Xtream Provider")
    }

    func testTolerantDecoderDefaultsMissingFields() throws {
        // Old on-disk shape lacks isEnabled / stripStreamIDs.
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Legacy",
            "type": {
                "m3u": {
                    "url": "https://legacy.example.com/list.m3u"
                }
            }
        }
        """

        let decoded = try JSONDecoder().decode(Provider.self, from: Data(legacyJSON.utf8))
        // isEnabled defaults to true; stripStreamIDs defaults to false.
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.stripStreamIDs)
    }

    func testStripStreamIDPrefix() {
        // ProviderManager's static helper used to clean up Xtream-style
        // "1234 | ChannelName" names.
        XCTAssertEqual(ProviderManager.stripStreamIDPrefix("123 | CNN HD"), "CNN HD")
        XCTAssertEqual(ProviderManager.stripStreamIDPrefix("CNN HD"), "CNN HD")
        XCTAssertEqual(ProviderManager.stripStreamIDPrefix("999| ESPN"), "ESPN")
    }
}
