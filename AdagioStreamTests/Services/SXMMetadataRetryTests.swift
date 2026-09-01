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

        service.matchChannels([makeChannel()], selectedGroupNames: ["SiriusXM"], sortPrefixes: [])
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

        service.matchChannels([makeChannel()], selectedGroupNames: ["SiriusXM"], sortPrefixes: [])
        let firstTask = service.matchTask
        // Prove the first loop is parked before superseding it — relying on
        // MainActor FIFO ordering here can hang forever if the scheduler
        // resumes the test first; a missed expectation is a bounded failure.
        await fulfillment(of: [firstParked], timeout: 5)

        service.matchChannels([makeChannel()], selectedGroupNames: ["SiriusXM"], sortPrefixes: [])
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
        service.matchChannels([channel], selectedGroupNames: ["SiriusXM"], sortPrefixes: [])
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

        service.matchChannels([makeChannel()], selectedGroupNames: ["SiriusXM"], sortPrefixes: [])
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

@MainActor
final class SXMExplicitGroupSelectionTests: XCTestCase {
    func testArbitraryExactSelectedGroupIsEligible() async {
        let service = service(stations: [(name: "Deep Space One", identifier: "space")])
        let channel = channel(id: "arbitrary", name: "Deep Space One", group: "My Satellite Picks")

        service.matchChannels(
            [channel], selectedGroupNames: ["My Satellite Picks"], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(service.channelDeeplinkMap, ["arbitrary": "space"])
    }

    func testUnselectedLegacyLookingGroupIsIneligibleWithoutFallback() async {
        let service = service(stations: [(name: "90s on 9", identifier: "8206")])
        let channel = channel(id: "legacy", name: "90s on 9", group: "SiriusXM")

        service.matchChannels([channel], selectedGroupNames: ["Something Else"], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
    }

    func testSelectionPreservesCaseAndWhitespaceDistinctions() async {
        let service = service(stations: [
            (name: "Exact", identifier: "exact"),
            (name: "Lower", identifier: "lower"),
            (name: "Spaced", identifier: "spaced")
        ])
        let channels = [
            channel(id: "exact", name: "Exact", group: "Chosen Group"),
            channel(id: "lower", name: "Lower", group: "chosen group"),
            channel(id: "spaced", name: "Spaced", group: " Chosen Group ")
        ]

        service.matchChannels(channels, selectedGroupNames: ["Chosen Group"], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(service.channelDeeplinkMap, ["exact": "exact"])
    }

    func testSameExactGroupNameSelectsChannelsAcrossAccounts() async {
        let service = service(stations: [
            (name: "Account One", identifier: "one"),
            (name: "Account Two", identifier: "two")
        ])
        var first = channel(id: "account-one", name: "Account One", group: "Shared Selection")
        first.providerName = "First Provider"
        var second = channel(id: "account-two", name: "Account Two", group: "Shared Selection")
        second.providerName = "Second Provider"

        service.matchChannels(
            [first, second], selectedGroupNames: ["Shared Selection"], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(
            service.channelDeeplinkMap,
            ["account-one": "one", "account-two": "two"]
        )
    }

    private func service(
        stations: [SXMMetadataService.MatchableStation]
    ) -> SXMMetadataService {
        let service = SXMMetadataService()
        service.stationListFetcher = { stations }
        return service
    }

    private func channel(id: String, name: String, group: String) -> Channel {
        Channel(
            id: id,
            name: name,
            streamURL: URL(string: "https://example.com/\(id)")!,
            group: group
        )
    }
}

@MainActor
final class SXMSelectionLifecycleTests: XCTestCase {
    func testDeselectionThenReselectionResumesUnchangedPlayingChannelAndRejectsLateTrack() async {
        let service = service()
        let selected = channel(id: "selected", name: "Selected", group: "Selected Group")
        service.stationListFetcher = {
            [(name: "Selected", identifier: "selected-station")]
        }
        service.matchChannels(
            [selected],
            selectedGroupNames: ["Selected Group"],
            sortPrefixes: []
        )
        await service.matchTask?.value

        var resumeTrack: CheckedContinuation<[SXMTrack]?, Never>?
        let trackStarted = expectation(description: "track request started")
        var trackRequests = 0
        service.trackFetcher = { _ in
            trackRequests += 1
            if trackRequests == 1 {
                return await withCheckedContinuation { continuation in
                    resumeTrack = continuation
                    trackStarted.fulfill()
                }
            }
            return [self.track(id: "resumed-track")]
        }
        service.channelChanged(to: selected)
        await fulfillment(of: [trackStarted], timeout: 1)
        service.currentTrack = track(id: "old-track")
        let lateTrackTask = service.trackTask

        service.matchChannels([selected], selectedGroupNames: [], sortPrefixes: [])

        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
        XCTAssertFalse(service.isSXMChannel)
        XCTAssertNil(service.currentTrack)

        service.matchChannels(
            [selected], selectedGroupNames: ["Selected Group"], sortPrefixes: [])
        await service.matchTask?.value
        await service.trackTask?.value

        XCTAssertEqual(trackRequests, 2, "reselection must resume polling for unchanged playback")
        XCTAssertTrue(service.isSXMChannel)
        XCTAssertEqual(service.currentTrack, track(id: "resumed-track"))

        resumeTrack?.resume(returning: [track(id: "late-track")])
        await lateTrackTask?.value

        XCTAssertTrue(service.isSXMChannel)
        XCTAssertEqual(
            service.currentTrack,
            track(id: "resumed-track"),
            "a cancelled old-selection request must not overwrite resumed metadata"
        )
        service.stopPolling()
    }

    func testExplicitStopDoesNotResumeTrackPollingOnRematch() async {
        let service = service()
        let selected = channel(id: "selected", name: "Selected", group: "Selected Group")
        service.stationListFetcher = { [(name: "Selected", identifier: "selected-station")] }
        var trackRequests = 0
        service.trackFetcher = { _ in
            trackRequests += 1
            return [self.track(id: "track-\(trackRequests)")]
        }
        service.matchChannels(
            [selected], selectedGroupNames: ["Selected Group"], sortPrefixes: [])
        await service.matchTask?.value
        service.channelChanged(to: selected)
        await service.trackTask?.value

        service.stopPolling()
        service.matchChannels(
            [selected], selectedGroupNames: ["Selected Group"], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(trackRequests, 1, "an explicit stop must forget the playing channel")
        XCTAssertFalse(service.isSXMChannel)
        XCTAssertNil(service.currentTrack)
    }

    func testDeselectionPreservesUnaffectedMappingsFeedAndCurrentMetadataWhileCatalogLoads() async {
        let service = service()
        let removed = channel(id: "removed", name: "Removed", group: "Removed Group")
        let retained = channel(id: "retained", name: "Retained", group: "Retained Group")
        let stations: [SXMMetadataService.MatchableStation] = [
            (name: "Removed", identifier: "removed-station"),
            (name: "Retained", identifier: "retained-station")
        ]
        service.stationListFetcher = { stations }
        service.feedFetcher = { [
            "removed-station": self.track(id: "removed-feed"),
            "retained-station": self.track(id: "retained-feed")
        ] }
        service.trackFetcher = { _ in [self.track(id: "retained-current")] }
        service.matchChannels(
            [removed, retained],
            selectedGroupNames: ["Removed Group", "Retained Group"],
            sortPrefixes: []
        )
        await service.matchTask?.value
        service.setFeedPollingEnabled(true)
        await service.feedTask?.value
        service.channelChanged(to: retained)
        await service.trackTask?.value

        var resumeCatalog: CheckedContinuation<[SXMMetadataService.MatchableStation]?, Never>?
        let catalogStarted = expectation(description: "replacement catalog request started")
        service.stationListFetcher = {
            await withCheckedContinuation { continuation in
                resumeCatalog = continuation
                catalogStarted.fulfill()
            }
        }
        service.matchChannels(
            [removed, retained], selectedGroupNames: ["Retained Group"], sortPrefixes: [])
        await fulfillment(of: [catalogStarted], timeout: 1)

        XCTAssertEqual(service.channelDeeplinkMap, ["retained": "retained-station"])
        XCTAssertEqual(service.feedTracks, ["retained": track(id: "retained-feed")])
        XCTAssertEqual(service.currentTrack, track(id: "retained-current"))
        XCTAssertTrue(service.isSXMChannel)

        resumeCatalog?.resume(returning: stations)
        await service.matchTask?.value
        service.setFeedPollingEnabled(false)
        service.stopPolling()
    }

    func testExplicitEmptySelectionClearsAllStateRejectsLateFeedAndStartsNoNewWork() async {
        let service = service()
        let selected = channel(id: "selected", name: "Selected", group: "Selected Group")
        service.stationListFetcher = { [(name: "Selected", identifier: "selected-station")] }
        service.feedFetcher = { ["selected-station": self.track(id: "old-feed")] }
        service.trackFetcher = { _ in [self.track(id: "old-current")] }
        service.matchChannels(
            [selected], selectedGroupNames: ["Selected Group"], sortPrefixes: [])
        await service.matchTask?.value
        service.setFeedPollingEnabled(true)
        await service.feedTask?.value
        service.channelChanged(to: selected)
        await service.trackTask?.value

        service.setFeedPollingEnabled(false)
        var resumeFeed: CheckedContinuation<[String: SXMTrack]?, Never>?
        let feedStarted = expectation(description: "old feed request started")
        var stationRequests = 0
        var feedRequests = 0
        var trackRequests = 0
        service.stationListFetcher = {
            stationRequests += 1
            return [(name: "Selected", identifier: "selected-station")]
        }
        service.feedFetcher = {
            feedRequests += 1
            return await withCheckedContinuation { continuation in
                resumeFeed = continuation
                feedStarted.fulfill()
            }
        }
        service.trackFetcher = { _ in
            trackRequests += 1
            return [self.track(id: "unexpected")]
        }
        service.setFeedPollingEnabled(true)
        await fulfillment(of: [feedStarted], timeout: 1)
        let lateFeedTask = service.feedTask

        service.matchChannels([selected], selectedGroupNames: [], sortPrefixes: [])

        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
        XCTAssertTrue(service.feedTracks.isEmpty)
        XCTAssertNil(service.currentTrack)
        XCTAssertFalse(service.isSXMChannel)
        XCTAssertEqual(stationRequests, 0)

        service.setFeedPollingEnabled(true)
        service.channelChanged(to: selected)
        XCTAssertEqual(feedRequests, 1, "empty selection must not schedule another feed request")
        XCTAssertEqual(trackRequests, 0, "an unmapped channel must not request a track")

        resumeFeed?.resume(returning: ["selected-station": track(id: "late-feed")])
        await lateFeedTask?.value
        XCTAssertTrue(service.feedTracks.isEmpty, "late feed work must not restore empty-selection state")
        service.setFeedPollingEnabled(false)
        service.stopPolling()
    }

    func testDeselectingSharedRawNameRemovesEveryAccountImmediately() async {
        let service = service()
        var first = channel(id: "account-one", name: "Account One", group: "Shared Group")
        first.providerName = "First"
        var second = channel(id: "account-two", name: "Account Two", group: "Shared Group")
        second.providerName = "Second"
        let retained = channel(id: "retained", name: "Retained", group: "Retained Group")
        service.stationListFetcher = {
            [(name: "Account One", identifier: "one"),
             (name: "Account Two", identifier: "two"),
             (name: "Retained", identifier: "retained")]
        }
        service.matchChannels(
            [first, second, retained],
            selectedGroupNames: ["Shared Group", "Retained Group"],
            sortPrefixes: []
        )
        await service.matchTask?.value

        var resumeCatalog: CheckedContinuation<[SXMMetadataService.MatchableStation]?, Never>?
        let catalogStarted = expectation(description: "replacement request started")
        service.stationListFetcher = {
            await withCheckedContinuation { continuation in
                resumeCatalog = continuation
                catalogStarted.fulfill()
            }
        }
        service.matchChannels(
            [first, second, retained], selectedGroupNames: ["Retained Group"], sortPrefixes: [])
        await fulfillment(of: [catalogStarted], timeout: 1)

        XCTAssertEqual(service.channelDeeplinkMap, ["retained": "retained"])

        resumeCatalog?.resume(returning: [(name: "Retained", identifier: "retained")])
        await service.matchTask?.value
    }

    func testRapidSelectionChangesPublishOnlyNewestStationResult() async {
        let service = service()
        let a = channel(id: "a", name: "A", group: "A Group")
        let b = channel(id: "b", name: "B", group: "B Group")
        let c = channel(id: "c", name: "C", group: "C Group")
        var continuations: [CheckedContinuation<[SXMMetadataService.MatchableStation]?, Never>] = []
        var requestCount = 0
        let firstStarted = expectation(description: "first request started")
        let secondStarted = expectation(description: "second request started")
        service.stationListFetcher = {
            requestCount += 1
            if requestCount == 3 { return [(name: "C", identifier: "newest")] }
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
                (requestCount == 1 ? firstStarted : secondStarted).fulfill()
            }
        }

        service.matchChannels([a, b, c], selectedGroupNames: ["A Group"], sortPrefixes: [])
        await fulfillment(of: [firstStarted], timeout: 1)
        let firstTask = service.matchTask
        service.matchChannels([a, b, c], selectedGroupNames: ["B Group"], sortPrefixes: [])
        await fulfillment(of: [secondStarted], timeout: 1)
        let secondTask = service.matchTask
        service.matchChannels([a, b, c], selectedGroupNames: ["C Group"], sortPrefixes: [])
        await service.matchTask?.value

        XCTAssertEqual(service.channelDeeplinkMap, ["c": "newest"])
        XCTAssertEqual(requestCount, 3)

        continuations[0].resume(returning: [(name: "A", identifier: "stale-a")])
        continuations[1].resume(returning: [(name: "B", identifier: "stale-b")])
        await firstTask?.value
        await secondTask?.value
        XCTAssertEqual(service.channelDeeplinkMap, ["c": "newest"])
    }

    func testSourceSwitchRetainsExplicitSelectionAndResumesEligibleChannel() async {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: SXMMetadataSource.defaultsKey)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: SXMMetadataSource.defaultsKey)
            } else {
                defaults.removeObject(forKey: SXMMetadataSource.defaultsKey)
            }
        }
        defaults.set(SXMMetadataSource.xmplaylist.rawValue, forKey: SXMMetadataSource.defaultsKey)

        let service = service()
        let selected = channel(id: "selected", name: "Selected", group: "Selected Group")
        let excluded = channel(id: "excluded", name: "Excluded", group: "Excluded Group")
        service.stationListFetcher = {
            [(name: "Selected", identifier: "old-source"),
             (name: "Excluded", identifier: "excluded-old")]
        }
        service.trackFetcher = { identifier in [self.track(id: identifier)] }
        service.matchChannels(
            [selected, excluded], selectedGroupNames: ["Selected Group"], sortPrefixes: [])
        await service.matchTask?.value
        service.channelChanged(to: selected)
        await service.trackTask?.value

        var newSourceRequests = 0
        service.stationListFetcher = {
            newSourceRequests += 1
            return [(name: "Selected", identifier: "new-source"),
                    (name: "Excluded", identifier: "excluded-new")]
        }
        defaults.set(SXMMetadataSource.stellartunerlog.rawValue, forKey: SXMMetadataSource.defaultsKey)
        service.sourceChanged()
        service.sourceChanged()
        await service.matchTask?.value
        await service.trackTask?.value

        XCTAssertEqual(newSourceRequests, 1)
        XCTAssertEqual(service.channelDeeplinkMap, ["selected": "new-source"])
        XCTAssertTrue(service.isSXMChannel)
        XCTAssertEqual(service.currentTrack, track(id: "new-source"))
        service.stopPolling()
    }

    func testSourceSwitchWithEmptySelectionStartsNoSXMWork() async {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: SXMMetadataSource.defaultsKey)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: SXMMetadataSource.defaultsKey)
            } else {
                defaults.removeObject(forKey: SXMMetadataSource.defaultsKey)
            }
        }
        defaults.set(SXMMetadataSource.xmplaylist.rawValue, forKey: SXMMetadataSource.defaultsKey)

        let service = service()
        let channel = channel(id: "legacy", name: "Legacy", group: "SiriusXM")
        var stationRequests = 0
        service.stationListFetcher = {
            stationRequests += 1
            return [(name: "Legacy", identifier: "legacy")]
        }
        service.matchChannels([channel], selectedGroupNames: [], sortPrefixes: [])

        defaults.set(SXMMetadataSource.stellartunerlog.rawValue, forKey: SXMMetadataSource.defaultsKey)
        service.sourceChanged()
        await service.matchTask?.value

        XCTAssertEqual(stationRequests, 0)
        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
    }

    func testSelectionChangeDuringSourceSwitchRejectsStaleResult() async {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: SXMMetadataSource.defaultsKey)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: SXMMetadataSource.defaultsKey)
            } else {
                defaults.removeObject(forKey: SXMMetadataSource.defaultsKey)
            }
        }
        defaults.set(SXMMetadataSource.xmplaylist.rawValue, forKey: SXMMetadataSource.defaultsKey)

        let service = service()
        let old = channel(id: "old", name: "Old", group: "Old Group")
        let new = channel(id: "new", name: "New", group: "New Group")
        service.stationListFetcher = { [(name: "Old", identifier: "initial")] }
        service.matchChannels([old, new], selectedGroupNames: ["Old Group"], sortPrefixes: [])
        await service.matchTask?.value

        var resumeSourceSwitch: CheckedContinuation<[SXMMetadataService.MatchableStation]?, Never>?
        let sourceSwitchStarted = expectation(description: "source switch rematch started")
        var stationRequests = 0
        service.stationListFetcher = {
            stationRequests += 1
            if stationRequests == 1 {
                return await withCheckedContinuation { continuation in
                    resumeSourceSwitch = continuation
                    sourceSwitchStarted.fulfill()
                }
            }
            return [(name: "New", identifier: "newest")]
        }
        defaults.set(SXMMetadataSource.stellartunerlog.rawValue, forKey: SXMMetadataSource.defaultsKey)
        service.sourceChanged()
        await fulfillment(of: [sourceSwitchStarted], timeout: 1)
        let staleTask = service.matchTask

        service.matchChannels([old, new], selectedGroupNames: ["New Group"], sortPrefixes: [])
        await service.matchTask?.value
        resumeSourceSwitch?.resume(returning: [(name: "Old", identifier: "stale")])
        await staleTask?.value

        XCTAssertEqual(service.channelDeeplinkMap, ["new": "newest"])
    }

    private func service() -> SXMMetadataService {
        let service = SXMMetadataService()
        service.retrySleep = { _ in true }
        return service
    }

    private func channel(id: String, name: String, group: String) -> Channel {
        Channel(
            id: id,
            name: name,
            streamURL: URL(string: "https://example.com/\(id)")!,
            group: group
        )
    }

    private func track(id: String) -> SXMTrack {
        SXMTrack(id: id, title: id, artists: ["Artist"], artworkURL: nil, startedAt: nil)
    }
}
