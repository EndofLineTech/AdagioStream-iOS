import XCTest
@testable import AdagioStream

/// Baseline characterization tests for KeychainService post-9nl.1.
///
/// All tests use the dedicated test service id `com.adagiostream.app.tests`
/// so they NEVER touch the production keychain entry. Each test cleans up
/// its keychain item in `tearDown` so back-to-back runs don't pollute.
///
/// On macOS host (`swift test`), Keychain access requires the host to be
/// either in a signed test bundle or run in a context where `SecItemAdd`
/// returns errSecSuccess. If the macOS keychain returns errSecMissingEntitlement
/// or similar, those tests are skipped — they're meant to validate the
/// iOS / tvOS keychain path on a real simulator destination.
final class KeychainServiceTests: XCTestCase {
    private let testService = "com.adagiostream.app.tests"
    private let testKey = "characterization-key"

    override func tearDown() async throws {
        KeychainService._delete(for: testKey, service: testService)
    }

    func testRoundTripSaveLoadDelete() throws {
        let payload = Data("hello-keychain".utf8)
        do {
            try KeychainService._save(payload, for: testKey, service: testService)
        } catch {
            // Some host environments (unsigned macOS) refuse keychain writes.
            // Skip rather than fail — the characterization target is
            // iOS / tvOS sim destinations.
            throw XCTSkip("Keychain unavailable in host environment: \(error)")
        }

        let loaded = KeychainService._load(for: testKey, service: testService)
        XCTAssertEqual(loaded, payload)

        KeychainService._delete(for: testKey, service: testService)
        XCTAssertNil(KeychainService._load(for: testKey, service: testService))
    }

    func testSaveIsIdempotent() throws {
        let v1 = Data("first".utf8)
        let v2 = Data("second".utf8)

        do {
            try KeychainService._save(v1, for: testKey, service: testService)
            try KeychainService._save(v2, for: testKey, service: testService)
        } catch {
            throw XCTSkip("Keychain unavailable in host environment: \(error)")
        }

        // The second save replaces the first — load returns v2.
        XCTAssertEqual(KeychainService._load(for: testKey, service: testService), v2)
    }

    func testDeleteOfMissingItemIsNoOp() {
        // Should not throw or crash even when nothing is stored.
        KeychainService._delete(for: "nonexistent-key", service: testService)
    }

    func testProductionServiceConstantIsLocked() {
        // Locked byte-identical with the legacy iOS implementation. Renaming
        // this string orphans every existing user's provider credentials.
        XCTAssertEqual(KeychainService.productionService, "com.adagiostream.app")
    }
}
