import XCTest
@testable import AdagioStream

/// Tests the foreground SXM poll-interval read+clamp: default when unset, and
/// clamping of out-of-range stored values so a garbage default can't produce a
/// runaway (or zero) timer. No network.
final class SXMPollIntervalTests: XCTestCase {
    private let key = SXMPollInterval.defaultsKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultWhenUnset() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(SXMPollInterval.current, TimeInterval(SXMPollInterval.defaultSeconds))
    }

    func testStoredValueInRangeIsUsed() {
        UserDefaults.standard.set(20, forKey: key)
        XCTAssertEqual(SXMPollInterval.current, 20)
    }

    func testClampsBelowMinimum() {
        UserDefaults.standard.set(2, forKey: key)
        XCTAssertEqual(SXMPollInterval.current, TimeInterval(SXMPollInterval.options.first!))
    }

    func testClampsAboveMaximum() {
        UserDefaults.standard.set(9999, forKey: key)
        XCTAssertEqual(SXMPollInterval.current, TimeInterval(SXMPollInterval.options.last!))
    }
}
