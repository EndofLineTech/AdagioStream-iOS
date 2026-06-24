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

    // MARK: - Subsonic Codec Tests

    func testMixedProviderArrayRoundTrip() throws {
        // Encode a mixed array containing all three ProviderType cases, then
        // decode it and verify every case round-trips intact with correct
        // associated values.
        let subsonicHost = URL(string: "https://music.example.com")!
        let m3uURL = URL(string: "https://example.com/list.m3u")!
        let xcHost = URL(string: "https://xc.example.com")!

        let providers: [Provider] = [
            Provider(
                name: "M3U Source",
                type: .m3u(url: m3uURL, epgURL: nil)
            ),
            Provider(
                name: "Xtream Source",
                type: .xtreamCodes(host: xcHost, username: "xcuser", password: "xcpass")
            ),
            Provider(
                name: "Subsonic Source",
                type: .subsonic(host: subsonicHost, username: "subuser", password: "subpass")
            ),
        ]

        let data = try JSONEncoder().encode(providers)
        let decoded = try JSONDecoder().decode([Provider].self, from: data)

        XCTAssertEqual(decoded.count, 3)

        // M3U case
        XCTAssertEqual(decoded[0].name, "M3U Source")
        guard case .m3u(let decodedM3UURL, _) = decoded[0].type else {
            return XCTFail("Expected .m3u for decoded[0]")
        }
        XCTAssertEqual(decodedM3UURL, m3uURL)

        // Xtream Codes case
        XCTAssertEqual(decoded[1].name, "Xtream Source")
        guard case .xtreamCodes(let decodedXCHost, let decodedXCUser, let decodedXCPass) = decoded[1].type else {
            return XCTFail("Expected .xtreamCodes for decoded[1]")
        }
        XCTAssertEqual(decodedXCHost, xcHost)
        XCTAssertEqual(decodedXCUser, "xcuser")
        XCTAssertEqual(decodedXCPass, "xcpass")

        // Subsonic case
        XCTAssertEqual(decoded[2].name, "Subsonic Source")
        guard case .subsonic(let decodedSubHost, let decodedSubUser, let decodedSubPass) = decoded[2].type else {
            return XCTFail("Expected .subsonic for decoded[2]")
        }
        XCTAssertEqual(decodedSubHost, subsonicHost)
        XCTAssertEqual(decodedSubUser, "subuser")
        XCTAssertEqual(decodedSubPass, "subpass")
    }

    func testSubsonicProviderHashable() {
        let host = URL(string: "https://music.example.com")!
        let a = Provider.ProviderType.subsonic(host: host, username: "u", password: "p")
        let b = Provider.ProviderType.subsonic(host: host, username: "u", password: "p")
        let c = Provider.ProviderType.subsonic(host: host, username: "other", password: "p")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        var set = Set<Provider.ProviderType>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Identical subsonic types should deduplicate in a Set")
    }
}
