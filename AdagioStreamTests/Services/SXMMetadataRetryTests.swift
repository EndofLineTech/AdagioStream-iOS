import XCTest
@testable import AdagioStream

/// Tests for the SXM station-list retry loop in matchChannels()
/// (beads_mobilemusic-k7m / beads_mobilemusic-t3s). Uses the stationListFetcher
/// and retrySleep seams — no wall-clock sleeps. The late-resume test does issue
/// one real track-fetch request that stopPolling() cancels immediately; this is
/// deliberate — seaming away the per-track fetch path is out of scope for this
/// bead. Fresh service instances per test avoid singleton state bleed.
@MainActor
final class SXMMetadataRetryTests: XCTestCase {

    private let stations: [SXMMetadataService.MatchableStation] = [
        (name: "90s on 9", identifier: "8206")
    ]

    private func makeChannel(_ id: String = "c1", name: String = "90s on 9") -> Channel {
        Channel(id: id, name: name, streamURL: URL(string: "http://example.com/\(id)")!, group: "SiriusXM")
    }

    // MARK: - Retry until success

    func testRetriesUntilSuccessWithCappedBackoff() async {
        let service = SXMMetadataService()
        var attempts = 0
        var delays: [TimeInterval] = []
        service.stationListFetcher = { [stations] in
            attempts += 1
            return attempts <= 6 ? nil : stations
        }
        service.retrySleep = { delays.append($0); return false }

        service.matchChannels([makeChannel()], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(attempts, 7)
        XCTAssertEqual(delays, [5, 10, 20, 40, 60, 60], "5s doubling, capped at 60s")
        XCTAssertEqual(service.channelDeeplinkMap["c1"], "8206", "matching table built after retries")
    }

    // MARK: - Generation supersession

    func testNewerMatchChannelsSupersedesOlderLoop() async {
        let service = SXMMetadataService()
        service.retrySleep = { _ in false }
        var fetchCount = 0
        var resumeFirst: CheckedContinuation<Void, Never>?
        let firstParked = expectation(description: "first loop parked on its fetch continuation")
        service.stationListFetcher = { [stations] in
            fetchCount += 1
            if fetchCount == 1 {
                // Gate the first loop's fetch until the test releases it,
                // then hand back a stale result that must NOT land.
                await withCheckedContinuation {
                    resumeFirst = $0
                    firstParked.fulfill()
                }
                return [(name: "90s on 9", identifier: "STALE")]
            }
            return stations
        }

        service.matchChannels([makeChannel()], sortPrefixes: [])
        let firstTask = service.matchTask
        // Prove the first loop is parked before superseding it — relying on
        // MainActor FIFO ordering here can hang forever if the scheduler
        // resumes the test first; a missed expectation is a bounded failure.
        await fulfillment(of: [firstParked], timeout: 5)

        service.matchChannels([makeChannel()], sortPrefixes: [])
        await service.matchTask?.value
        XCTAssertEqual(service.channelDeeplinkMap["c1"], "8206", "newest attempt lands")

        resumeFirst?.resume()
        await firstTask?.value  // superseded loop exits via the generation guard
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(service.channelDeeplinkMap["c1"], "8206", "stale loop must not overwrite the table")
    }

    // MARK: - Late resume

    func testLateStationListSuccessResumesCurrentChannel() async {
        let service = SXMMetadataService()
        service.retrySleep = { _ in false }
        service.stationListFetcher = { [stations] in stations }

        let channel = makeChannel()
        service.matchChannels([channel], sortPrefixes: [])
        // The loop task has not run yet (no suspension point crossed): the map
        // is still empty when the channel starts playing.
        service.channelChanged(to: channel)
        XCTAssertFalse(service.isSXMChannel, "no metadata while the map is empty")

        await service.matchTask?.value  // fetch succeeds, table builds, late resume re-runs channelChanged
        XCTAssertTrue(service.isSXMChannel, "channelChanged re-ran after late station-list success")
        service.stopPolling()  // cancel the immediate track fetch + poll timer before they run
    }

    // MARK: - Cancellation exit

    func testCancelledSleepExitsLoop() async {
        let service = SXMMetadataService()
        var attempts = 0
        var sleeps = 0
        service.stationListFetcher = { attempts += 1; return nil }
        service.retrySleep = { _ in sleeps += 1; return true }  // report cancellation

        service.matchChannels([makeChannel()], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(attempts, 1, "no further fetch attempts after cancellation")
        XCTAssertEqual(sleeps, 1)
        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
    }

    // MARK: - Default retrySleep polarity

    func testDefaultRetrySleepReportsCancellation() async {
        // The other tests all replace retrySleep; this pins the polarity of the
        // production default — cancelled sleep must return true so the loop
        // exits instead of hot-looping. A cancelled Task.sleep throws
        // immediately, so this never waits the 10s.
        let service = SXMMetadataService()
        let t = Task { await service.retrySleep(10) }
        t.cancel()
        let cancelled = await t.value
        XCTAssertTrue(cancelled, "default retrySleep must report cancellation")
    }
}
