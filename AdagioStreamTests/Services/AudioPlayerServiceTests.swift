// AudioPlayerService is iOS-only per Phase 0 G2. The smoke test here
// exercises only the @MainActor-isolated symbol presence and a couple
// of trivial state queries on the singleton — full state-machine
// coverage is out of scope for Phase 0.
//
// Gated `#if os(iOS)` so the tvOS test target does not link the symbol.

#if os(iOS)
import XCTest
@testable import AdagioStream

@MainActor
final class AudioPlayerServiceTests: XCTestCase {

    func testSingletonIsAccessible() {
        // Purely a smoke check: the symbol exists, the singleton resolves,
        // and a couple of @Published properties read with their default
        // values. We do NOT exercise actual playback — that requires a
        // real audio session.
        let service = AudioPlayerService.shared
        XCTAssertNotNil(service)
        XCTAssertNil(service.currentChannel)
        XCTAssertFalse(service.isPlaying)
        XCTAssertFalse(service.isBuffering)
    }
}
#endif
