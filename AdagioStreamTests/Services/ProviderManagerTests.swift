import Combine
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

    // MARK: - serverProviders filtering (beads_mobilemusic-jt8)

    @MainActor
    func testServerProvidersExcludesM3U() {
        let manager = ProviderManager()
        manager.providers = [
            Provider(name: "M3U", type: .m3u(url: URL(string: "https://e.com/a.m3u")!, epgURL: nil)),
            Provider(name: "Xtream", type: .xtreamCodes(host: URL(string: "https://x.com")!, username: "u", password: "p")),
            Provider(name: "Navidrome", type: .subsonic(host: URL(string: "https://n.com")!, username: "u", password: "p")),
            Provider(name: "ABS", type: .audiobookshelf(host: URL(string: "https://a.com")!, username: "u", password: "p")),
        ]

        let names = manager.serverProviders.map(\.name)
        XCTAssertEqual(names, ["Xtream", "Navidrome", "ABS"], "M3U must be excluded from serverProviders; server types preserved in order")
    }

    // MARK: - Subsonic addProvider / updateProvider validation via seam
    //
    // ProviderManager constructs NavidromeAPI internally, so injecting a real
    // mock URLSession through ProviderManager would require a larger refactor.
    // The chosen seam is a `subsonicPingValidator` closure on ProviderManager
    // (nil in production, overridden in tests). This keeps the seam minimal
    // and avoids changing the production init path.

    @MainActor
    func testAddSubsonicProviderSucceedsPersistsProvider() async {
        let manager = ProviderManager()
        // Inject a ping validator that always succeeds.
        manager.subsonicPingValidator = { _, _, _ in /* success */ }

        let provider = Provider(
            name: "My Navidrome",
            type: .subsonic(
                host: URL(string: "http://nas.local:4533")!,
                username: "alice",
                password: "secret"
            )
        )

        await manager.addProvider(provider)

        XCTAssertNil(manager.error, "No error should be set after a successful ping")
        XCTAssertTrue(
            manager.providers.contains(where: { $0.name == "My Navidrome" }),
            "Provider should be persisted after ping succeeds"
        )
    }

    @MainActor
    func testAddSubsonicProviderPingFailureDoesNotPersist() async {
        let manager = ProviderManager()
        // Inject a ping validator that always fails with an auth error.
        manager.subsonicPingValidator = { _, _, _ in
            throw NavidromeAPI.APIError.authenticationFailed
        }

        let provider = Provider(
            name: "Bad Navidrome",
            type: .subsonic(
                host: URL(string: "http://nas.local:4533")!,
                username: "wrong",
                password: "wrongpass"
            )
        )

        await manager.addProvider(provider)

        XCTAssertNotNil(manager.error, "Error should be set after ping failure")
        XCTAssertFalse(
            manager.providers.contains(where: { $0.name == "Bad Navidrome" }),
            "Provider must NOT be persisted when ping fails"
        )
        // beads_mobilemusic-uxf: a validation failure (not a loadChannels()
        // failure) must not surface as channelLoadError — that's the signal
        // CarPlay's root placeholder and tvOS's ChannelsTabView key off of to
        // show "Couldn't load channels", and this path never touched channels.
        XCTAssertNil(
            manager.channelLoadError,
            "channelLoadError must stay nil for a validation failure, unlike the shared `error` field"
        )
    }

    // MARK: - Cancellation guard (beads_mobilemusic-uxb.1 / kickback regression net)
    //
    // addProvider re-checks Task.isCancelled immediately before mutating
    // `providers`, so a Cancel/dismiss racing the in-flight validation never
    // lets a half-added provider slip through. Pins that contract: even when
    // validation itself succeeds, an already-cancelled Task must leave
    // `providers` untouched.

    @MainActor
    func testAddProviderInCancelledTaskLeavesProvidersEmpty() async {
        let manager = ProviderManager()
        manager.subsonicPingValidator = { _, _, _ in /* success */ }

        let provider = Provider(
            name: "Cancelled Add",
            type: .subsonic(
                host: URL(string: "http://nas.local:4533")!,
                username: "alice",
                password: "secret"
            )
        )

        let task = Task { @MainActor in
            await manager.addProvider(provider)
        }
        task.cancel()
        await task.value

        XCTAssertTrue(
            manager.providers.isEmpty,
            "A Task cancelled before/during addProvider must never mutate providers, even when validation succeeds"
        )
    }

    // MARK: - loadChannels(from:) for .subsonic returns [] without throwing

    @MainActor
    func testLoadChannelsFromSubsonicReturnsEmptyWithoutThrowing() async throws {
        let manager = ProviderManager()
        let provider = Provider(
            name: "Subsonic Library",
            type: .subsonic(
                host: URL(string: "https://music.example.com")!,
                username: "u",
                password: "p"
            )
        )

        // Should NOT throw and MUST return an empty array.
        let channels = try await manager.loadChannels(from: provider)
        XCTAssertTrue(channels.isEmpty, "Subsonic must return [] from loadChannels(from:) in E1 — library loading is deferred to E2")
    }
}

final class SXMRawChannelGroupInventoryTests: XCTestCase {
    private var settingsFilename: String?

    override func tearDown() async throws {
        if let settingsFilename {
            await PersistenceService.shared.delete(settingsFilename)
        }
        await PersistenceService.shared.delete(Constants.StorageKeys.customPlaylists)
    }

    @MainActor
    func testInventoryDeduplicatesOnlyIdenticalRawNamesAcrossAccounts() {
        let manager = ProviderManager(automaticallyLoad: false)

        manager.recordRawChannelGroupInventory(
            from: [
                channel(id: "shared", group: "SiriusXM"),
                channel(id: "shared", group: "SiriusXM"),
                channel(id: "lower", group: "siriusxm"),
                channel(id: "spaced", group: " SiriusXM "),
                channel(id: "suffix", group: "SiriusXM: Rock")
            ],
            loadSucceeded: true
        )

        XCTAssertEqual(
            manager.availableRawChannelGroupNames,
            ["SiriusXM", "siriusxm", " SiriusXM ", "SiriusXM: Rock"]
        )
        XCTAssertEqual(
            manager.availableRawChannelGroupCounts,
            ["SiriusXM": 2, "siriusxm": 1, " SiriusXM ": 1, "SiriusXM: Rock": 1]
        )
        XCTAssertTrue(manager.hasLoadedCompleteRawChannelGroupInventory)
    }

    @MainActor
    func testFailedLoadDoesNotPublishPartialInventoryAsComplete() {
        let manager = ProviderManager(automaticallyLoad: false)

        manager.recordRawChannelGroupInventory(
            from: [channel(id: "partial", group: "SiriusXM")],
            loadSucceeded: false
        )

        XCTAssertEqual(manager.availableRawChannelGroupNames, [])
        XCTAssertFalse(manager.hasLoadedCompleteRawChannelGroupInventory)
    }

    @MainActor
    func testCustomOnlyCompleteInventoryIncludesCustomGroup() {
        let manager = ProviderManager(automaticallyLoad: false)
        let playlists = [playlist(group: "SiriusXM Custom")]

        manager.rebuildWithCustomPlaylists(from: playlists)
        manager.updateRawChannelGroupInventory(providerChannels: [], loadSucceeded: true)

        XCTAssertEqual(manager.availableRawChannelGroupNames, ["SiriusXM Custom"])
        XCTAssertTrue(manager.hasLoadedCompleteRawChannelGroupInventory)
    }

    @MainActor
    func testCustomOnlyLegacyStartupWaitsForHydrationBeforeMigrationAndObservesLaterUpdates() async throws {
        let filename = "sxm-custom-startup-\(UUID().uuidString).json"
        settingsFilename = filename
        try await PersistenceService.shared.save(
            AppSettings(hasCompletedSXMGroupSelectionMigration: false),
            to: filename
        )
        var resumeHydration: CheckedContinuation<[CustomPlaylist], Never>?
        let hydrationStarted = expectation(description: "custom playlist hydration started")
        let customPlaylistManager = CustomPlaylistManager {
            await withCheckedContinuation { continuation in
                resumeHydration = continuation
                hydrationStarted.fulfill()
            }
        }
        let manager = ProviderManager(
            automaticallyLoad: false,
            customPlaylistManager: customPlaylistManager
        )
        let viewModel = SettingsViewModel(
            audioPlayer: .shared,
            providerManager: manager,
            settingsFilename: filename,
            automaticallyLoad: false
        )
        let playlist = playlist(group: "SiriusXM Persisted")
        await viewModel.loadSettings()

        let startup = Task { await manager.loadChannelsWithoutProviders() }
        await fulfillment(of: [hydrationStarted], timeout: 1)

        XCTAssertFalse(manager.hasLoadedCompleteRawChannelGroupInventory)
        XCTAssertTrue(manager.availableRawChannelGroupNames.isEmpty)
        XCTAssertFalse(viewModel.settings.hasCompletedSXMGroupSelectionMigration)

        let migrated = expectation(description: "legacy selection migrates after hydration")
        var migrationCancellable: AnyCancellable?
        migrationCancellable = viewModel.$settings.sink { settings in
            if settings.hasCompletedSXMGroupSelectionMigration {
                migrated.fulfill()
            }
        }

        resumeHydration?.resume(returning: [playlist])
        await startup.value
        await fulfillment(of: [migrated], timeout: 1)
        _ = migrationCancellable

        XCTAssertTrue(manager.hasLoadedCompleteRawChannelGroupInventory)
        XCTAssertEqual(manager.availableRawChannelGroupNames, ["SiriusXM Persisted"])
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["SiriusXM Persisted"])
        let persisted: AppSettings = try await PersistenceService.shared.load(from: filename)
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["SiriusXM Persisted"])

        let rebuilt = expectation(description: "later playlist update rebuilds inventory")
        var didObserveRebuild = false
        var cancellable: AnyCancellable?
        cancellable = manager.$availableRawChannelGroupNames.dropFirst().sink { names in
            if names == ["SiriusXM Renamed"], !didObserveRebuild {
                didObserveRebuild = true
                rebuilt.fulfill()
            }
        }
        customPlaylistManager.renameGroup(
            playlist.groups[0].id,
            to: "SiriusXM Renamed",
            in: playlist.id
        )
        await fulfillment(of: [rebuilt], timeout: 1)
        _ = cancellable

        XCTAssertEqual(manager.availableRawChannelGroupNames, ["SiriusXM Renamed"])
    }

    @MainActor
    func testCustomChangesRefreshInventoryAfterSuccessfulBaseline() {
        let manager = ProviderManager(automaticallyLoad: false)
        manager.updateRawChannelGroupInventory(
            providerChannels: [channel(id: "provider", group: "Provider Group")],
            loadSucceeded: true
        )

        manager.rebuildWithCustomPlaylists(from: [playlist(group: "Custom Created")])
        XCTAssertEqual(manager.availableRawChannelGroupNames, ["Provider Group", "Custom Created"])

        manager.rebuildWithCustomPlaylists(from: [playlist(group: "Custom Renamed")])
        XCTAssertEqual(manager.availableRawChannelGroupNames, ["Provider Group", "Custom Renamed"])

        manager.rebuildWithCustomPlaylists(from: [])
        XCTAssertEqual(manager.availableRawChannelGroupNames, ["Provider Group"])
    }

    @MainActor
    func testCustomChangesDoNotCompleteInventoryAfterFailedProviderLoad() {
        let manager = ProviderManager(automaticallyLoad: false)
        manager.updateRawChannelGroupInventory(
            providerChannels: [channel(id: "baseline", group: "Complete Baseline")],
            loadSucceeded: true
        )

        manager.updateRawChannelGroupInventory(
            providerChannels: [channel(id: "partial", group: "Partial Provider")],
            loadSucceeded: false
        )
        manager.rebuildWithCustomPlaylists(from: [playlist(group: "Custom After Failure")])

        XCTAssertEqual(manager.availableRawChannelGroupNames, ["Complete Baseline"])
        XCTAssertTrue(manager.hasLoadedCompleteRawChannelGroupInventory)
    }

    @MainActor
    func testPersistedSelectionAndHiddenRawChannelsReachSXMMatching() async throws {
        let filename = "sxm-runtime-selection-\(UUID().uuidString).json"
        settingsFilename = filename
        try await PersistenceService.shared.save(
            AppSettings(selectedSXMGroupNames: ["Hidden Satellites"]),
            to: filename
        )
        let manager = ProviderManager(automaticallyLoad: false, settingsFilename: filename)
        var matchedChannels: [Channel] = []
        var matchedSelection: Set<String> = []
        manager.sxmChannelMatcher = { channels, selectedGroupNames in
            matchedChannels = channels
            matchedSelection = selectedGroupNames
        }
        await manager.loadPersistedSettings()
        manager.rebuildWithCustomPlaylists(from: [
            playlist(group: "Visible Group"),
            playlist(group: "Hidden Satellites")
        ])
        await manager.setAllGroupsEnabled(false)

        manager.refreshSXMChannelMatches()

        XCTAssertTrue(manager.channels.isEmpty, "the display filter hides every raw group")
        XCTAssertEqual(Set(matchedChannels.map(\.group)), ["Visible Group", "Hidden Satellites"])
        XCTAssertEqual(matchedSelection, ["Hidden Satellites"])
        await manager.setAllGroupsEnabled(true)
    }

    @MainActor
    func testProviderInventoryExcludesGroupsDiscardedByRuntimeIDDeduplication() async {
        let manager = ProviderManager(automaticallyLoad: false)
        manager.providers = [provider(name: "First"), provider(name: "Second")]
        manager.providerChannelLoader = { provider in
            if provider.name == "First" {
                return [
                    self.channel(id: "duplicate", group: "Runtime Group"),
                    self.channel(id: "first-shared", group: "Shared Group")
                ]
            }
            return [
                self.channel(id: "duplicate", group: "Discarded Group"),
                self.channel(id: "second-shared", group: "Shared Group")
            ]
        }

        await manager.loadChannels()

        XCTAssertEqual(manager.availableRawChannelGroupNames, ["Runtime Group", "Shared Group"])
        XCTAssertEqual(
            manager.availableRawChannelGroupCounts,
            ["Runtime Group": 1, "Shared Group": 2]
        )
        XCTAssertEqual(Set(manager.channels.map(\.group)), ["Runtime Group", "Shared Group"])
        XCTAssertFalse(manager.availableRawChannelGroupNames.contains("Discarded Group"))
    }

    private func channel(id: String, group: String) -> Channel {
        Channel(
            id: id,
            name: id,
            streamURL: URL(string: "https://example.com/\(id)")!,
            group: group
        )
    }

    private func playlist(group: String) -> CustomPlaylist {
        CustomPlaylist(
            name: "Test Playlist",
            groups: [
                CustomPlaylistGroup(
                    name: group,
                    entries: [
                        CustomPlaylistEntry(
                            name: "Test Channel",
                            streamURL: URL(string: "https://example.com/\(UUID().uuidString)")!
                        )
                    ]
                )
            ]
        )
    }

    private func provider(name: String) -> Provider {
        Provider(
            name: name,
            type: .subsonic(
                host: URL(string: "https://example.com")!,
                username: "user",
                password: "password"
            )
        )
    }
}

@MainActor
final class SXMRematchTriggerTests: XCTestCase {
    func testProviderRebuildCompletionUsesLatestSelectionAcrossAccounts() async {
        let manager = ProviderManager(automaticallyLoad: false)
        let service = metadataService(stations: [
            (name: "Account One", identifier: "one"),
            (name: "Account Two", identifier: "two"),
            (name: "Excluded", identifier: "excluded")
        ])
        manager.providers = [provider(name: "One"), provider(name: "Two")]

        var resumeFirstProvider: CheckedContinuation<[Channel], Never>?
        let firstProviderStarted = expectation(description: "provider rebuild started")
        manager.providerChannelLoader = { provider in
            if provider.name == "One" {
                return await withCheckedContinuation { continuation in
                    resumeFirstProvider = continuation
                    firstProviderStarted.fulfill()
                }
            }
            return [
                self.channel(id: "account-two", name: "Account Two", group: "Shared Group"),
                self.channel(id: "excluded", name: "Excluded", group: "Excluded Group")
            ]
        }

        var completedRebuildSelections: [Set<String>] = []
        manager.sxmChannelMatcher = { channels, selection in
            if !channels.isEmpty { completedRebuildSelections.append(selection) }
            service.matchChannels(channels, selectedGroupNames: selection, sortPrefixes: [])
        }
        manager.setSXMGroupSelection(["Old Group"])

        let rebuild = Task { await manager.loadChannels() }
        await fulfillment(of: [firstProviderStarted], timeout: 1)
        manager.setSXMGroupSelection(["Shared Group"])
        resumeFirstProvider?.resume(returning: [
            channel(id: "account-one", name: "Account One", group: "Shared Group")
        ])
        await rebuild.value
        await service.matchTask?.value

        XCTAssertEqual(completedRebuildSelections, [["Shared Group"]])
        XCTAssertEqual(service.channelDeeplinkMap, [
            "account-one": "one",
            "account-two": "two"
        ])
    }

    func testProviderRebuildWithEmptySelectionStartsNoSXMWork() async {
        let manager = ProviderManager(automaticallyLoad: false)
        manager.providers = [provider(name: "Provider")]
        manager.providerChannelLoader = { _ in
            [self.channel(id: "legacy", name: "Legacy", group: "SiriusXM")]
        }
        var stationRequests = 0
        let service = metadataService(stations: [])
        service.stationListFetcher = {
            stationRequests += 1
            return [(name: "Legacy", identifier: "legacy")]
        }
        manager.sxmChannelMatcher = { channels, selection in
            service.matchChannels(channels, selectedGroupNames: selection, sortPrefixes: [])
        }

        await manager.loadChannels()
        await service.matchTask?.value

        XCTAssertEqual(stationRequests, 0)
        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
    }

    func testCustomGroupRebuildRematchesOnceAndIgnoresUnselectedGroups() async {
        let manager = ProviderManager(automaticallyLoad: false)
        let service = metadataService(stations: [
            (name: "Selected Station", identifier: "selected"),
            (name: "Excluded Station", identifier: "excluded")
        ])
        manager.setSXMGroupSelection(["Selected Group"])
        var completedRebuildSelections: [Set<String>] = []
        manager.sxmChannelMatcher = { channels, selection in
            completedRebuildSelections.append(selection)
            service.matchChannels(channels, selectedGroupNames: selection, sortPrefixes: [])
        }

        manager.rebuildWithCustomPlaylists(from: [
            playlist(name: "Selected", group: "Selected Group", station: "Selected Station"),
            playlist(name: "Excluded", group: "Excluded Group", station: "Excluded Station")
        ])
        await service.matchTask?.value

        XCTAssertEqual(completedRebuildSelections, [["Selected Group"]])
        XCTAssertEqual(Set(service.channelDeeplinkMap.values), ["selected"])
    }

    func testCustomGroupRebuildWithEmptySelectionStartsNoSXMWork() async {
        let manager = ProviderManager(automaticallyLoad: false)
        var stationRequests = 0
        let service = metadataService(stations: [])
        service.stationListFetcher = {
            stationRequests += 1
            return [(name: "Station", identifier: "station")]
        }
        manager.sxmChannelMatcher = { channels, selection in
            service.matchChannels(channels, selectedGroupNames: selection, sortPrefixes: [])
        }

        manager.rebuildWithCustomPlaylists(from: [
            playlist(name: "Custom", group: "SiriusXM", station: "Station")
        ])
        await service.matchTask?.value

        XCTAssertEqual(stationRequests, 0)
        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
    }

    func testMetadataSourceChangeRematchesOnceUsingLatestExactSelectionAcrossAccounts() async {
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

        let service = metadataService(stations: [(name: "Old", identifier: "old")])
        var first = channel(id: "account-one", name: "Account One", group: "Shared Group")
        first.providerName = "First Provider"
        var second = channel(id: "account-two", name: "Account Two", group: "Shared Group")
        second.providerName = "Second Provider"
        let excluded = channel(id: "excluded", name: "Excluded", group: "shared group")
        let old = channel(id: "old", name: "Old", group: "Old Group")
        let channels = [first, second, excluded, old]
        service.matchChannels(channels, selectedGroupNames: ["Old Group"], sortPrefixes: [])
        await service.matchTask?.value

        service.stationListFetcher = {
            [(name: "Account One", identifier: "initial-one"),
             (name: "Account Two", identifier: "initial-two"),
             (name: "Excluded", identifier: "initial-excluded")]
        }
        service.matchChannels(channels, selectedGroupNames: ["Shared Group"], sortPrefixes: [])
        await service.matchTask?.value

        var sourceRematches = 0
        service.stationListFetcher = {
            sourceRematches += 1
            return [(name: "Account One", identifier: "new-one"),
                    (name: "Account Two", identifier: "new-two"),
                    (name: "Excluded", identifier: "new-excluded")]
        }
        defaults.set(SXMMetadataSource.stellartunerlog.rawValue, forKey: SXMMetadataSource.defaultsKey)
        service.sourceChanged()
        service.sourceChanged()
        await service.matchTask?.value

        XCTAssertEqual(sourceRematches, 1)
        XCTAssertEqual(service.channelDeeplinkMap, [
            "account-one": "new-one",
            "account-two": "new-two"
        ])
    }

    func testSelectionChangeDuringCustomRebuildRejectsStaleResult() async {
        let manager = ProviderManager(automaticallyLoad: false)
        let service = metadataService(stations: [])
        var resumeOldSelection: CheckedContinuation<[SXMMetadataService.MatchableStation]?, Never>?
        var stationRequests = 0
        let oldSelectionStarted = expectation(description: "old selection rematch started")
        service.stationListFetcher = {
            stationRequests += 1
            if stationRequests == 1 {
                return await withCheckedContinuation { continuation in
                    resumeOldSelection = continuation
                    oldSelectionStarted.fulfill()
                }
            }
            return [(name: "New Station", identifier: "new")]
        }
        manager.sxmChannelMatcher = { channels, selection in
            service.matchChannels(channels, selectedGroupNames: selection, sortPrefixes: [])
        }
        manager.setSXMGroupSelection(["Old Group"])
        manager.rebuildWithCustomPlaylists(from: [
            playlist(name: "Old", group: "Old Group", station: "Old Station"),
            playlist(name: "New", group: "New Group", station: "New Station")
        ])
        await fulfillment(of: [oldSelectionStarted], timeout: 1)
        let staleTask = service.matchTask

        manager.setSXMGroupSelection(["New Group"])
        await service.matchTask?.value
        resumeOldSelection?.resume(returning: [(name: "Old Station", identifier: "old")])
        await staleTask?.value

        XCTAssertEqual(Set(service.channelDeeplinkMap.values), ["new"])
    }

    private func metadataService(
        stations: [SXMMetadataService.MatchableStation]
    ) -> SXMMetadataService {
        let service = SXMMetadataService()
        service.stationListFetcher = { stations }
        service.retrySleep = { _ in true }
        return service
    }

    private func provider(name: String) -> Provider {
        Provider(
            name: name,
            type: .subsonic(
                host: URL(string: "https://example.com")!,
                username: "user",
                password: "password"
            )
        )
    }

    private func channel(id: String, name: String, group: String) -> Channel {
        Channel(
            id: id,
            name: name,
            streamURL: URL(string: "https://example.com/\(id)")!,
            group: group
        )
    }

    private func playlist(
        name: String,
        group: String,
        station: String
    ) -> CustomPlaylist {
        CustomPlaylist(
            name: name,
            groups: [
                CustomPlaylistGroup(
                    name: group,
                    entries: [
                        CustomPlaylistEntry(
                            name: station,
                            streamURL: URL(string: "https://example.com/\(name)")!
                        )
                    ]
                )
            ]
        )
    }
}

@MainActor
final class SXMGroupSelectionMigrationTests: XCTestCase {
    private var settingsFilename: String!

    override func setUp() async throws {
        settingsFilename = "sxm-group-migration-\(UUID().uuidString).json"
    }

    override func tearDown() async throws {
        await PersistenceService.shared.delete(settingsFilename)
        settingsFilename = nil
    }

    func testLegacyInstallationMigratesMatchingExactNamesAndPersistsCompletion() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = completeManager(groups: ["News", "SiriusXM", "sxm", "XM Sports", "SiriusXMish"])
        let viewModel = makeViewModel(providerManager: manager)

        await viewModel.loadSettings()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["SiriusXM", "sxm", "XM Sports"])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, viewModel.settings.selectedSXMGroupNames)
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)
    }

    func testPendingLegacyInstallationMigratesWhenFirstCompleteInventoryArrives() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = ProviderManager(automaticallyLoad: false)
        let viewModel = makeViewModel(providerManager: manager)
        await viewModel.loadSettings()
        let migrated = expectation(description: "inventory publication triggers migration")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$settings.dropFirst().sink { settings in
            if settings.hasCompletedSXMGroupSelectionMigration {
                migrated.fulfill()
            }
        }

        manager.recordRawChannelGroupInventory(
            from: [channel(id: "sxm", group: "Sirius XM")],
            loadSucceeded: true
        )
        await fulfillment(of: [migrated], timeout: 1)
        _ = cancellable

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Sirius XM"])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["Sirius XM"])
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)
    }

    func testRepeatedCompleteInventoryDoesNotRunMigrationAgain() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = completeManager(groups: ["SiriusXM"])
        let viewModel = makeViewModel(providerManager: manager)
        await viewModel.loadSettings()

        manager.recordRawChannelGroupInventory(
            from: [channel(id: "new", group: "XM Sports")],
            loadSucceeded: true
        )
        await viewModel.migrateSXMGroupSelectionIfNeeded()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["SiriusXM"])
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["SiriusXM"])
    }

    func testCompletedExplicitEmptySelectionIsNeverOverwritten() async throws {
        try await saveSettings(.default)
        let manager = completeManager(groups: ["SiriusXM"])
        let viewModel = makeViewModel(providerManager: manager)

        await viewModel.loadSettings()
        await viewModel.migrateSXMGroupSelectionIfNeeded()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
    }

    func testNewInstallRemainsExplicitEmptyAndCompleted() async {
        let manager = completeManager(groups: ["SiriusXM"])
        let viewModel = makeViewModel(providerManager: manager)

        await viewModel.loadSettings()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
    }

    func testSelectionUpdatePersistsMarksMigrationCompleteAndRematchesImmediately() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = ProviderManager(automaticallyLoad: false)
        var matchedSelections: [Set<String>] = []
        manager.sxmChannelMatcher = { _, selection in
            matchedSelections.append(selection)
        }
        let viewModel = makeViewModel(providerManager: manager)
        await viewModel.loadSettings()

        await viewModel.updateSXMGroupSelection([" SiriusXM ", "siriusxm"])

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [" SiriusXM ", "siriusxm"])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(manager.selectedSXMGroupNames, [" SiriusXM ", "siriusxm"])
        XCTAssertEqual(matchedSelections, [[" SiriusXM ", "siriusxm"]])
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, [" SiriusXM ", "siriusxm"])
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)

        await viewModel.updateSXMGroupSelection([])

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        XCTAssertEqual(manager.selectedSXMGroupNames, [])
        XCTAssertEqual(matchedSelections, [[" SiriusXM ", "siriusxm"], []])
        let emptyPersisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(emptyPersisted.selectedSXMGroupNames, [])
        XCTAssertTrue(emptyPersisted.hasCompletedSXMGroupSelectionMigration)
    }

    func testCompleteEmptyInventoryPersistsCompletedExplicitEmptyAndIgnoresLaterGroups() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = ProviderManager(automaticallyLoad: false)
        manager.recordRawChannelGroupInventory(from: [], loadSucceeded: true)
        let viewModel = makeViewModel(providerManager: manager)

        await viewModel.loadSettings()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        var persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)

        manager.recordRawChannelGroupInventory(
            from: [channel(id: "later", group: "SiriusXM Later")],
            loadSucceeded: true
        )
        await viewModel.migrateSXMGroupSelectionIfNeeded()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        persisted = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, [])
    }

    func testPendingMigrationWaitsThroughFailedPartialInventory() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = ProviderManager(automaticallyLoad: false)
        manager.recordRawChannelGroupInventory(
            from: [channel(id: "partial", group: "SiriusXM")],
            loadSucceeded: false
        )
        let viewModel = makeViewModel(providerManager: manager)

        await viewModel.loadSettings()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        XCTAssertFalse(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
    }

    func testCustomOnlyInstallationMigratesFromCompleteCombinedInventory() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = ProviderManager(automaticallyLoad: false)
        manager.rebuildWithCustomPlaylists(
            from: [
                CustomPlaylist(
                    name: "Custom",
                    groups: [
                        CustomPlaylistGroup(
                            name: "SiriusXM Custom",
                            entries: [
                                CustomPlaylistEntry(
                                    name: "Custom Station",
                                    streamURL: URL(string: "https://example.com/custom")!
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        manager.updateRawChannelGroupInventory(providerChannels: [], loadSucceeded: true)
        let viewModel = makeViewModel(providerManager: manager)

        await viewModel.loadSettings()

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["SiriusXM Custom"])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
    }

    func testSXMWriteStartedFirstCannotOverwriteOrdinarySettingThatFinishesFirst() async throws {
        let prior = AppSettings(selectedSXMGroupNames: ["Prior Group"])
        try await saveSettings(prior)
        let manager = ProviderManager(automaticallyLoad: false)
        var resumeFirstSave: CheckedContinuation<Void, Never>?
        var saveAttempts = 0
        let firstSaveStarted = expectation(description: "SXM save started")
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { settings, filename in
                saveAttempts += 1
                if saveAttempts == 1 {
                    firstSaveStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        resumeFirstSave = continuation
                    }
                }
                try await PersistenceService.shared.save(settings, to: filename)
            }
        )
        await viewModel.loadSettings()

        let sxmUpdate = Task {
            await viewModel.updateSXMGroupSelection(["New Group"])
        }
        await fulfillment(of: [firstSaveStarted], timeout: 1)
        let ordinaryUpdate = Task { await viewModel.updateAppearance(.dark) }
        await Task.yield()

        resumeFirstSave?.resume()
        let sxmSaved = await sxmUpdate.value
        XCTAssertTrue(sxmSaved)
        await ordinaryUpdate.value

        XCTAssertEqual(saveAttempts, 2)
        XCTAssertEqual(viewModel.settings.appearanceMode, .dark)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["New Group"])
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.appearanceMode, .dark)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["New Group"])
    }

    func testOrdinaryWriteStartedFirstCannotBeOverwrittenByQueuedSXMWrite() async throws {
        let prior = AppSettings(selectedSXMGroupNames: ["Prior Group"])
        try await saveSettings(prior)
        let manager = ProviderManager(automaticallyLoad: false)
        var resumeFirstSave: CheckedContinuation<Void, Never>?
        var saveAttempts = 0
        let firstSaveStarted = expectation(description: "ordinary save started")
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { settings, filename in
                saveAttempts += 1
                if saveAttempts == 1 {
                    firstSaveStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        resumeFirstSave = continuation
                    }
                }
                try await PersistenceService.shared.save(settings, to: filename)
            }
        )
        await viewModel.loadSettings()

        let ordinaryUpdate = Task { await viewModel.updateAppearance(.dark) }
        await fulfillment(of: [firstSaveStarted], timeout: 1)
        let sxmUpdate = Task {
            await viewModel.updateSXMGroupSelection(["New Group"])
        }
        await Task.yield()

        resumeFirstSave?.resume()
        await ordinaryUpdate.value
        let sxmSaved = await sxmUpdate.value
        XCTAssertTrue(sxmSaved)

        XCTAssertEqual(saveAttempts, 2)
        XCTAssertEqual(viewModel.settings.appearanceMode, .dark)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["New Group"])
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.appearanceMode, .dark)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["New Group"])
    }

    func testFailedSXMWriteDoesNotBlockQueuedOrdinarySettingPersistence() async throws {
        let prior = AppSettings(selectedSXMGroupNames: ["Prior Group"])
        try await saveSettings(prior)
        let manager = ProviderManager(automaticallyLoad: false)
        var resumeFirstSave: CheckedContinuation<Void, Never>?
        var saveAttempts = 0
        let firstSaveStarted = expectation(description: "SXM save started")
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { settings, filename in
                saveAttempts += 1
                if saveAttempts == 1 {
                    firstSaveStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        resumeFirstSave = continuation
                    }
                    throw TestPersistenceError.writeFailed
                }
                try await PersistenceService.shared.save(settings, to: filename)
            }
        )
        await viewModel.loadSettings()

        let sxmUpdate = Task {
            await viewModel.updateSXMGroupSelection(["Failed Group"])
        }
        await fulfillment(of: [firstSaveStarted], timeout: 1)
        let ordinaryUpdate = Task { await viewModel.updateAppearance(.dark) }

        resumeFirstSave?.resume()
        let sxmSaved = await sxmUpdate.value
        XCTAssertFalse(sxmSaved)
        await ordinaryUpdate.value

        XCTAssertEqual(saveAttempts, 2)
        XCTAssertEqual(viewModel.settings.appearanceMode, .dark)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertNotNil(viewModel.settingsError)
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.appearanceMode, .dark)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["Prior Group"])
    }

    func testSelectionPersistenceFailureLeavesDiskViewModelAndRuntimeAtPriorSelection() async throws {
        let prior = AppSettings(selectedSXMGroupNames: ["Prior Group"])
        try await saveSettings(prior)
        let manager = ProviderManager(automaticallyLoad: false)
        var matchedSelections: [Set<String>] = []
        manager.sxmChannelMatcher = { _, selection in matchedSelections.append(selection) }
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { _, _ in throw TestPersistenceError.writeFailed }
        )
        await viewModel.loadSettings()
        matchedSelections.removeAll()

        let saved = await viewModel.updateSXMGroupSelection(["Candidate Group"])

        XCTAssertFalse(saved)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertTrue(matchedSelections.isEmpty)
        XCTAssertNotNil(viewModel.settingsError)
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["Prior Group"])
    }

    func testConcurrentSelectionUpdateIsRejectedUntilFirstTransactionPublishes() async throws {
        let prior = AppSettings(selectedSXMGroupNames: ["Prior Group"])
        try await saveSettings(prior)
        let manager = ProviderManager(automaticallyLoad: false)
        var matchedSelections: [Set<String>] = []
        manager.sxmChannelMatcher = { _, selection in matchedSelections.append(selection) }
        var resumeFirstSave: CheckedContinuation<Void, Never>?
        var saveAttempts = 0
        let firstSaveStarted = expectation(description: "first selection save started")
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { settings, filename in
                saveAttempts += 1
                if saveAttempts == 1 {
                    firstSaveStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        resumeFirstSave = continuation
                    }
                }
                try await PersistenceService.shared.save(settings, to: filename)
            }
        )
        await viewModel.loadSettings()
        matchedSelections.removeAll()

        let firstUpdate = Task {
            await viewModel.updateSXMGroupSelection(["First Candidate"])
        }
        await fulfillment(of: [firstSaveStarted], timeout: 1)

        XCTAssertTrue(viewModel.isSXMSelectionPersistenceInFlight)
        let secondSaved = await viewModel.updateSXMGroupSelection(["Second Candidate"])

        XCTAssertFalse(secondSaved)
        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertTrue(matchedSelections.isEmpty)
        var persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["Prior Group"])

        resumeFirstSave?.resume()
        let firstSaved = await firstUpdate.value

        XCTAssertTrue(firstSaved)
        XCTAssertFalse(viewModel.isSXMSelectionPersistenceInFlight)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["First Candidate"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["First Candidate"])
        XCTAssertEqual(matchedSelections, [["First Candidate"]])
        persisted = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["First Candidate"])
    }

    func testSelectionPersistenceFlagResetsAfterFailureAndAllowsRetry() async throws {
        let prior = AppSettings(selectedSXMGroupNames: ["Prior Group"])
        try await saveSettings(prior)
        let manager = ProviderManager(automaticallyLoad: false)
        var matchedSelections: [Set<String>] = []
        manager.sxmChannelMatcher = { _, selection in matchedSelections.append(selection) }
        var saveAttempts = 0
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { settings, filename in
                saveAttempts += 1
                if saveAttempts == 1 { throw TestPersistenceError.writeFailed }
                try await PersistenceService.shared.save(settings, to: filename)
            }
        )
        await viewModel.loadSettings()
        matchedSelections.removeAll()

        let firstSaved = await viewModel.updateSXMGroupSelection(["Failed Candidate"])

        XCTAssertFalse(firstSaved)
        XCTAssertFalse(viewModel.isSXMSelectionPersistenceInFlight)
        XCTAssertNotNil(viewModel.settingsError)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertTrue(matchedSelections.isEmpty)

        let retrySaved = await viewModel.updateSXMGroupSelection(["Retry Candidate"])

        XCTAssertTrue(retrySaved)
        XCTAssertFalse(viewModel.isSXMSelectionPersistenceInFlight)
        XCTAssertNil(viewModel.settingsError)
        XCTAssertEqual(saveAttempts, 2)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Retry Candidate"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["Retry Candidate"])
        XCTAssertEqual(matchedSelections, [["Retry Candidate"]])
        let persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["Retry Candidate"])
    }

    func testDelayedMigrationPersistenceFailureRemainsPendingAndRetries() async throws {
        try await saveSettings(.init(hasCompletedSXMGroupSelectionMigration: false))
        let manager = ProviderManager(automaticallyLoad: false)
        let viewModel = makeViewModel(providerManager: manager)
        await viewModel.loadSettings()
        var attempts = 0
        let firstFailurePublished = expectation(description: "delayed migration reports save failure")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$settingsError.compactMap { $0 }.sink { _ in
            firstFailurePublished.fulfill()
        }
        viewModel.settingsSaver = { settings, filename in
            attempts += 1
            if attempts == 1 { throw TestPersistenceError.writeFailed }
            try await PersistenceService.shared.save(settings, to: filename)
        }

        manager.recordRawChannelGroupInventory(
            from: [channel(id: "sxm", group: "SiriusXM Retry")],
            loadSucceeded: true
        )
        await fulfillment(of: [firstFailurePublished], timeout: 1)
        _ = cancellable

        XCTAssertFalse(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(manager.selectedSXMGroupNames, [])
        var persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertFalse(persisted.hasCompletedSXMGroupSelectionMigration)

        await viewModel.migrateSXMGroupSelectionIfNeeded()

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["SiriusXM Retry"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["SiriusXM Retry"])
        persisted = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)
    }

    func testInitialMigrationPersistenceFailureDoesNotPublishCompletion() async throws {
        let prior = AppSettings(
            selectedSXMGroupNames: ["Prior Group"],
            hasCompletedSXMGroupSelectionMigration: false
        )
        try await saveSettings(prior)
        let manager = completeManager(groups: ["SiriusXM Candidate"])
        let viewModel = makeViewModel(
            providerManager: manager,
            settingsSaver: { _, _ in throw TestPersistenceError.writeFailed }
        )

        await viewModel.loadSettings()

        XCTAssertFalse(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["Prior Group"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["Prior Group"])
        var persisted: AppSettings = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertFalse(persisted.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(persisted.selectedSXMGroupNames, ["Prior Group"])

        viewModel.settingsSaver = { settings, filename in
            try await PersistenceService.shared.save(settings, to: filename)
        }
        await viewModel.migrateSXMGroupSelectionIfNeeded()

        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, ["SiriusXM Candidate"])
        XCTAssertEqual(manager.selectedSXMGroupNames, ["SiriusXM Candidate"])
        persisted = try await PersistenceService.shared.load(from: settingsFilename)
        XCTAssertTrue(persisted.hasCompletedSXMGroupSelectionMigration)
    }

    func testDeleteEverythingRuntimeResetStaysExplicitEmptyThroughChannelRebuild() async throws {
        let manager = ProviderManager(automaticallyLoad: false)
        let service = SXMMetadataService()
        service.stationListFetcher = { [(name: "Old Station", identifier: "old-station")] }
        service.trackFetcher = { _ in [self.track(id: "old-track")] }
        var runtimeChannels: [Channel] = []
        manager.sxmChannelMatcher = { channels, selection in
            runtimeChannels = channels
            service.matchChannels(channels, selectedGroupNames: selection, sortPrefixes: [])
        }
        manager.rebuildWithCustomPlaylists(from: [
            playlist(name: "Old", group: "Old Group", station: "Old Station")
        ])
        manager.setSXMGroupSelection(["Old Group"])
        await service.matchTask?.value
        let oldChannel = try XCTUnwrap(runtimeChannels.first)
        service.channelChanged(to: oldChannel)
        await service.trackTask?.value
        XCTAssertTrue(service.isSXMChannel)
        XCTAssertEqual(service.currentTrack, track(id: "old-track"))
        var settings = AppSettings.default
        settings.selectedSXMGroupNames = ["Old Group"]
        let viewModel = makeViewModel(providerManager: manager)
        viewModel.settings = settings

        DataDeletionService.resetRuntimeState(
            settingsViewModel: viewModel,
            providerManager: manager,
            sxmMetadataService: service
        )

        XCTAssertEqual(viewModel.settings.selectedSXMGroupNames, [])
        XCTAssertTrue(viewModel.settings.hasCompletedSXMGroupSelectionMigration)
        XCTAssertEqual(manager.selectedSXMGroupNames, [])
        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
        XCTAssertFalse(service.isSXMChannel)

        var stationRequests = 0
        service.stationListFetcher = {
            stationRequests += 1
            return [(name: "Old Station", identifier: "old-station")]
        }
        manager.rebuildWithCustomPlaylists(from: [
            playlist(name: "Old", group: "Old Group", station: "Old Station")
        ])
        await service.matchTask?.value

        XCTAssertEqual(manager.selectedSXMGroupNames, [])
        XCTAssertEqual(stationRequests, 0)
        XCTAssertTrue(service.channelDeeplinkMap.isEmpty)
    }

    private func makeViewModel(
        providerManager: ProviderManager,
        settingsSaver: SettingsViewModel.SettingsSaver? = nil
    ) -> SettingsViewModel {
        SettingsViewModel(
            audioPlayer: .shared,
            providerManager: providerManager,
            settingsFilename: settingsFilename,
            automaticallyLoad: false,
            settingsSaver: settingsSaver
        )
    }

    private func completeManager(groups: [String]) -> ProviderManager {
        let manager = ProviderManager(automaticallyLoad: false)
        manager.recordRawChannelGroupInventory(
            from: groups.enumerated().map { channel(id: "channel-\($0.offset)", group: $0.element) },
            loadSucceeded: true
        )
        return manager
    }

    private func channel(id: String, group: String) -> Channel {
        Channel(
            id: id,
            name: id,
            streamURL: URL(string: "https://example.com/\(id)")!,
            group: group
        )
    }

    private func saveSettings(_ settings: AppSettings) async throws {
        try await PersistenceService.shared.save(settings, to: settingsFilename)
    }

    private func playlist(name: String, group: String, station: String) -> CustomPlaylist {
        CustomPlaylist(
            name: name,
            groups: [
                CustomPlaylistGroup(
                    name: group,
                    entries: [
                        CustomPlaylistEntry(
                            name: station,
                            streamURL: URL(string: "https://example.com/\(name)")!
                        )
                    ]
                )
            ]
        )
    }

    private func track(id: String) -> SXMTrack {
        SXMTrack(id: id, title: id, artists: ["Artist"], artworkURL: nil, startedAt: nil)
    }

    private enum TestPersistenceError: Error {
        case writeFailed
    }
}

final class SiriusXMGroupSelectionStateTests: XCTestCase {
    func testSelectionStateLabelsAndSummaryData() {
        let state = SiriusXMGroupSelectionState(
            inventory: ["News": 3, "Sports": 5],
            selectedNames: ["News"]
        )

        XCTAssertEqual(SiriusXMGroupSelectionState.settingsRowTitle, "SiriusXM Channel Groups")
        XCTAssertEqual(SiriusXMGroupSelectionState.navigationTitle, "SiriusXM Groups")
        XCTAssertEqual(state.summary, "1 Selected")
        XCTAssertEqual(state.availableRows.first(where: { $0.name == "News" })?.selectionLabel, "Selected")
        XCTAssertEqual(state.availableRows.first(where: { $0.name == "Sports" })?.selectionLabel, "Not Selected")
    }

    func testAvailableRowsAreStableAlphabeticAndSearchable() {
        let state = SiriusXMGroupSelectionState(
            inventory: ["Zulu": 1, "alpha": 2, "Alpha": 3, "Beta": 4],
            selectedNames: ["Beta"],
            searchText: "ALP"
        )

        XCTAssertEqual(state.availableRows.map(\.name), ["Alpha", "alpha"])
        XCTAssertEqual(state.availableRows.map(\.channelCount), [3, 2])
    }

    func testSameExactNameRendersOnceWhileCaseAndWhitespaceRemainDistinct() {
        let state = SiriusXMGroupSelectionState(
            inventory: ["SiriusXM": 4, "siriusxm": 2, " SiriusXM ": 1],
            selectedNames: []
        )

        XCTAssertEqual(Set(state.availableRows.map(\.name)), ["SiriusXM", "siriusxm", " SiriusXM "])
        XCTAssertEqual(state.availableRows.filter { $0.name == "SiriusXM" }.count, 1)
    }

    func testTogglingRowsSupportsSelectedUnselectedAndExplicitEmpty() {
        let state = SiriusXMGroupSelectionState(
            inventory: ["News": 3, "Sports": 5],
            selectedNames: ["News"]
        )

        XCTAssertEqual(state.selection(toggling: "Sports"), ["News", "Sports"])
        XCTAssertEqual(state.selection(toggling: "News"), [])
        XCTAssertEqual(
            SiriusXMGroupSelectionState(inventory: ["News": 3], selectedNames: []).summary,
            "None"
        )
    }

    func testUnavailableSelectionsRemainVisibleSearchableAndDeselectable() {
        let state = SiriusXMGroupSelectionState(
            inventory: ["Available": 2],
            selectedNames: ["Available", "Missing Group"],
            searchText: "missing"
        )

        XCTAssertTrue(state.availableRows.isEmpty)
        XCTAssertEqual(state.unavailableRows.map(\.name), ["Missing Group"])
        XCTAssertTrue(state.unavailableRows[0].isSelected)
        XCTAssertTrue(state.unavailableRows[0].isUnavailable)
        XCTAssertEqual(state.selection(toggling: "Missing Group"), ["Available"])
        XCTAssertEqual(state.summary, "2 Selected (1 Unavailable)")
    }

    func testIncompleteInventoryDoesNotMarkPersistedSelectionsUnavailable() {
        let state = SiriusXMGroupSelectionState(
            inventory: [:],
            selectedNames: ["Still Loading"],
            inventoryIsComplete: false
        )

        XCTAssertTrue(state.unavailableRows.isEmpty)
        XCTAssertFalse(state.hasUnfilteredRows)
        XCTAssertEqual(state.summary, "1 Selected")
    }
}
