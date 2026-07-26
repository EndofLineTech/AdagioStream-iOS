import Combine
import Foundation
import SwiftUI

/// Lightweight summary of a newly-added provider, surfaced by
/// `ProviderManager.newProviderInfo` so consuming UIs can render a
/// "provider added — X groups, Y channels" toast.
public struct NewProviderInfo: Identifiable {
    public let id = UUID()
    public let providerName: String
    public let groupCount: Int
    public let channelCount: Int
}

/// App-wide provider + channel state. Owns the persisted provider list
/// (Keychain), channel materialization from each provider, EPG merge,
/// favorite + group preferences, and downstream metadata service hooks.
@MainActor
public final class ProviderManager: ObservableObject {
    public static let shared = ProviderManager()

    @Published public var providers: [Provider] = []
    @Published public var newProviderInfo: NewProviderInfo?
    @Published public var channels: [Channel] = []
    @Published public var epgData: [String: [EPGEntry]] = [:]
    @Published public var isLoading = false
    @Published public var error: String?
    /// True once `loadProviders()` has completed at least once. `providers`
    /// starts as an empty array and hydrates asynchronously from Keychain at
    /// launch — before this flips, `providers.isEmpty` is indistinguishable
    /// from "genuinely no accounts configured" (uxa kickback finding 4:
    /// CarPlay's root placeholder read the pre-hydration empty array as
    /// "unconfigured" for a real account, briefly).
    @Published public private(set) var didHydrateProviders = false
    /// Section keys (group names + the Favorites sentinel) the user has
    /// expanded. Empty by default so every section starts collapsed, and
    /// groups appearing later start collapsed too. Session-only, not persisted.
    @Published public var expandedGroups: Set<String> = []
    @Published public private(set) var favoriteOrder: [String] = []
    @Published public private(set) var enabledGroups: Set<String>? = nil
    @Published public private(set) var favoriteGroupOrder: [String] = []
    @Published public private(set) var channelCountByProvider: [UUID: Int] = [:]
    @Published public private(set) var sortedVisibleGroups: [ChannelGroup] = []
    @Published public private(set) var allGroupCounts: [String: Int] = [:]
    @Published public var channelSortOrder: ChannelSortOrder = .providerOrder
    @Published public var groupSortOrder: ChannelSortOrder = .providerOrder
    @Published public var channelGroupingMode: ChannelGroupingMode = .allGroups
    /// CarPlay root ordering of Navidrome music vs streaming channel groups
    /// (fnv.9). Mirrors AppSettings.carPlaySourceOrder; CarPlayTemplateManager
    /// observes this to rebuild the root list when it changes.
    @Published public var carPlaySourceOrder: CarPlaySourceOrder = .streamingFirst
    private var rawChannels: [Channel] = []
    private var providerRawChannels: [Channel] = []
    private var isLoadingChannels = false
    private var cancellables = Set<AnyCancellable>()

    private let persistence = PersistenceService.shared

    /// Test seam: overrides the Subsonic ping logic so unit tests can inject
    /// a mock validator without constructing a real NavidromeAPI.
    /// Production code leaves this nil; ProviderManager then uses NavidromeAPI directly.
    /// Tests set this to a closure that throws on failure or returns on success.
    var subsonicPingValidator: ((URL, String, String) async throws -> Void)?

    public init() {
        // Migrate legacy Keychain items to iCloud-syncable attributes
        // BEFORE any keychain read in this init path. Idempotent; see
        // KeychainSyncMigrator and bead 9nl.2. Synchronous so subsequent
        // KeychainService.load calls below (loadProviders) observe the
        // post-migration state.
        KeychainSyncMigrator.runIfNeeded()

        // Re-merge custom playlist channels whenever playlists change
        CustomPlaylistManager.shared.$playlists
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebuildWithCustomPlaylists()
                }
            }
            .store(in: &cancellables)

        Task {
            let settings: AppSettings = await persistence.loadOrDefault(
                from: Constants.StorageKeys.settings, default: .default
            )
            channelSortOrder = settings.channelSortOrder
            groupSortOrder = settings.groupSortOrder
            channelGroupingMode = settings.channelGroupingMode
            carPlaySourceOrder = settings.carPlaySourceOrder
            await loadProviders()
            if !providers.isEmpty {
                await loadChannels()
            } else {
                // No providers — still merge custom playlist channels
                favoriteOrder = await loadFavoriteOrder()
                appendCustomPlaylistChannels()
                applyGroupFilter()
            }
        }
    }

    public func loadProviders() async {
        defer { didHydrateProviders = true }
        // Try Keychain first
        if let data = KeychainService.load(for: Constants.StorageKeys.providers),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            providers = decoded
            return
        }

        // Migration: load from plaintext file, move to Keychain, delete file
        let fileProviders: [Provider] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.providers, default: []
        )
        providers = fileProviders
        if !fileProviders.isEmpty {
            await saveProviders()
            await persistence.delete(Constants.StorageKeys.providers)
        }
    }

    /// Validates a candidate provider's credentials/connectivity before it is
    /// persisted.  Subsonic providers are validated via `ping.view` (not
    /// channel count — a fresh library has 0 songs and that's valid). M3U/XC
    /// providers are validated by loading channels and rejecting empty
    /// results.  Sets `self.error` and returns `false` on failure; the caller
    /// is responsible for not persisting the candidate in that case.
    ///
    /// `context` is only used to prefix debug log lines (`"addProvider"` /
    /// `"updateProvider"`) — shared by both call sites (beads_mobilemusic-t96.9).
    private func validateProvider(_ provider: Provider, context: String) async -> Bool {
        if case .subsonic(let host, let username, let password) = provider.type {
            // Subsonic: validate connectivity + auth via ping.view.
            // 0 channels is NOT an error for Subsonic (library loading is E2).
            let pingFn = subsonicPingValidator
                ?? { h, u, p in try await NavidromeAPI(host: h, username: u, password: p).ping() }
            do {
                try await pingFn(host, username, password)
                DebugLogger.shared.log(
                    "\(context)[\(provider.name)]: Subsonic ping OK",
                    category: .providers
                )
            } catch let apiError as NavidromeAPI.APIError {
                error = apiError.errorDescription ?? "Connection failed."
                DebugLogger.shared.log(
                    "\(context)[\(provider.name)]: REJECTED — Subsonic ping failed: \(String(describing: apiError))",
                    category: .providers
                )
                return false
            } catch {
                self.error = error.localizedDescription
                DebugLogger.shared.log(
                    "\(context)[\(provider.name)]: REJECTED — Subsonic ping failed: \(String(describing: error))",
                    category: .providers
                )
                return false
            }
        } else if case .audiobookshelf(let host, let username, let password) = provider.type {
            // Audiobookshelf: validate connectivity + auth by logging in and
            // listing libraries. 0 books is NOT an error (library loading is a
            // later epic), mirroring the Subsonic ping approach.
            do {
                let auth = AudiobookshelfAuth(
                    host: host, username: username, password: password,
                    providerID: provider.id.uuidString
                )
                // OIDC/SSO providers have no password — their tokens are already
                // seeded in the Keychain by the sign-in flow. Skip login() and
                // validate directly; authorizedData uses the seeded tokens.
                if !provider.type.isAudiobookshelfOIDC {
                    _ = try await auth.login()
                }
                let api = AudiobookshelfAPI(host: host, auth: auth)
                _ = try await api.bookLibraries()
                DebugLogger.shared.log(
                    "\(context)[\(provider.name)]: Audiobookshelf login + libraries OK",
                    category: .providers
                )
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DebugLogger.shared.log(
                    "\(context)[\(provider.name)]: REJECTED — Audiobookshelf validation failed: \(String(describing: error))",
                    category: .providers
                )
                return false
            }
        } else {
            // M3U / XC: validate by loading channels; reject if empty.
            do {
                let validated = try await loadChannelsWithRetry(from: provider, attempts: 2)
                if validated.isEmpty {
                    error = "\(provider.name): playlist returned no channels"
                    DebugLogger.shared.log(
                        "\(context)[\(provider.name)]: REJECTED — 0 channels from validation",
                        category: .providers
                    )
                    return false
                }
            } catch let validationError {
                error = "\(provider.name): \(validationError.localizedDescription)"
                DebugLogger.shared.log(
                    "\(context)[\(provider.name)]: REJECTED — \(String(describing: validationError))",
                    category: .providers
                )
                return false
            }
        }
        return true
    }

    public func addProvider(_ provider: Provider, enableAllGroups: Bool = false) async {
        // Pre-validate the candidate provider before touching the persisted
        // provider list.  loadChannels(from:) may set self.error as a
        // non-fatal EPG warning during validation; reset to a known state on
        // entry and let the full refresh below repopulate it.
        error = nil

        guard await validateProvider(provider, context: "addProvider") else { return }

        // Discard any EPG warning set during validation; the full refresh
        // below re-runs the EPG fetch and will set this if it's still true.
        error = nil

        // beads_mobilemusic-uxb.1: re-check right before the mutation, not just
        // at the awaits inside validateProvider — validation can finish and
        // cancellation can land in the same instant, and a caller (e.g.
        // AddProviderView's Cancel/dismiss) must never see a half-added provider.
        guard !Task.isCancelled else { return }

        let existingGroups = Set(rawChannels.map(\.group))

        providers.append(provider)
        await saveProviders()
        await loadChannels()

        // Disable groups that are new from this provider (unless enableAllGroups is set)
        let allGroups = Set(rawChannels.map(\.group))
        let newGroups = allGroups.subtracting(existingGroups)

        if !newGroups.isEmpty {
            if enableAllGroups {
                // First-time setup: keep all groups enabled
                enabledGroups = nil
                await saveEnabledGroups()
                applyGroupFilter()
            } else {
                if enabledGroups == nil {
                    // Was "all enabled" — switch to explicit set excluding new groups
                    enabledGroups = allGroups.subtracting(newGroups)
                } else {
                    enabledGroups = enabledGroups?.subtracting(newGroups)
                }
                await saveEnabledGroups()
                applyGroupFilter()

                newProviderInfo = NewProviderInfo(
                    providerName: provider.name,
                    groupCount: newGroups.count,
                    channelCount: channelCountByProvider[provider.id] ?? 0
                )
            }
        }
    }

    public func deleteProvider(_ provider: Provider) async {
        providers.removeAll { $0.id == provider.id }
        await saveProviders()
        if providers.isEmpty {
            providerRawChannels = []
            rawChannels = []
            channels = []
            epgData = [:]
            allGroupCounts = [:]
            error = nil
            // Re-merge custom playlist channels even with no providers
            rebuildWithCustomPlaylists()
        }
    }

    public func updateProvider(_ provider: Provider) async {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else {
            return
        }

        // Pre-validate, same pattern as addProvider: if the updated
        // credentials fail validation, leave the prior good config untouched
        // in providers / on disk.
        error = nil

        guard await validateProvider(provider, context: "updateProvider") else { return }

        error = nil

        // beads_mobilemusic-uxb.1: same cancellation re-check as addProvider.
        guard !Task.isCancelled else { return }

        providers[index] = provider
        await saveProviders()
        await loadChannels()
    }

    public func toggleProviderEnabled(_ provider: Provider) async {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index].isEnabled.toggle()
            await saveProviders()
            await loadChannels()
        }
    }

    public var enabledProviderCount: Int {
        providers.filter(\.isEnabled).count
    }

    /// Server-type providers only (Xtream / Navidrome / Audiobookshelf), excluding
    /// M3U. M3U providers are managed exclusively from the Custom M3Us tab, so the
    /// Settings → Accounts lists show only server accounts (beads_mobilemusic-jt8).
    public var serverProviders: [Provider] {
        providers.filter {
            if case .m3u = $0.type { return false }
            return true
        }
    }

    /// Returns a `NavidromeAPI` client for the first enabled Subsonic provider,
    /// or `nil` when none is configured.
    ///
    /// Single-server product scope: when multiple Subsonic providers are
    /// configured, the first enabled one wins.  The browse UI (`MusicLibraryView`)
    /// reads this once on appear; the accessor is cheap (no network I/O).
    public var subsonicAPI: NavidromeAPI? {
        for provider in providers where provider.isEnabled {
            if case .subsonic(let host, let username, let password) = provider.type {
                return NavidromeAPI(host: host, username: username, password: password)
            }
        }
        return nil
    }

    /// Returns an `AudiobookshelfAPI` client for the first enabled ABS provider,
    /// or `nil` when none is configured. Mirrors `subsonicAPI`: single-server
    /// scope, first enabled wins, cheap (no network I/O). The auth actor reuses
    /// the Keychain tokens persisted under the provider id.
    public var audiobookshelfAPI: AudiobookshelfAPI? {
        for provider in providers where provider.isEnabled {
            if case .audiobookshelf(let host, let username, let password) = provider.type {
                let auth = AudiobookshelfAuth(
                    host: host, username: username, password: password,
                    providerID: provider.id.uuidString
                )
                return AudiobookshelfAPI(host: host, auth: auth)
            }
        }
        return nil
    }

    private func saveProviders() async {
        do {
            let data = try JSONEncoder().encode(providers)
            try KeychainService.save(data, for: Constants.StorageKeys.providers)
        } catch {
            self.error = "Failed to save providers: \(error.localizedDescription)"
        }
    }

    nonisolated private static let streamIDPrefixPattern = try! NSRegularExpression(pattern: #"^\d+\s*\|\s*"#)

    public nonisolated static func stripStreamIDPrefix(_ name: String) -> String {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = streamIDPrefixPattern.firstMatch(in: name, range: range),
              let swiftRange = Range(match.range, in: name) else { return name }
        return String(name[swiftRange.upperBound...])
    }

    // MARK: - Channel Loading

    public func loadChannels() async {
        guard !isLoadingChannels else {
            DebugLogger.shared.log("loadChannels: skipped — already loading", category: .providers)
            return
        }
        isLoadingChannels = true
        defer { isLoadingChannels = false }
        isLoading = true
        error = nil

        let enabled = providers.filter(\.isEnabled)
        let m3uCount = enabled.filter { if case .m3u = $0.type { return true } else { return false } }.count
        let xcCount = enabled.filter { if case .xtreamCodes = $0.type { return true } else { return false } }.count
        let subsonicCount = enabled.filter { if case .subsonic = $0.type { return true } else { return false } }.count
        DebugLogger.shared.log(
            "loadChannels: starting — \(enabled.count) enabled providers (\(m3uCount) M3U, \(xcCount) XC, \(subsonicCount) Subsonic)",
            category: .providers
        )

        var allChannels: [Channel] = []
        var errors: [String] = []
        var counts: [UUID: Int] = [:]

        for provider in enabled {
            let typeLabel: String = {
                switch provider.type {
                case .m3u: return "M3U"
                case .xtreamCodes: return "XC"
                case .subsonic: return "Subsonic"
                case .audiobookshelf: return "Audiobookshelf"
                }
            }()
            DebugLogger.shared.log(
                "loadChannels: loading \(typeLabel) provider \"\(provider.name)\"",
                category: .providers
            )
            do {
                var loaded = try await loadChannelsWithRetry(from: provider, attempts: 2)
                for i in loaded.indices {
                    if provider.stripStreamIDs {
                        let ch = loaded[i]
                        loaded[i] = Channel(
                            id: ch.id,
                            name: Self.stripStreamIDPrefix(ch.name),
                            streamURL: ch.streamURL,
                            logoURL: ch.logoURL,
                            group: ch.group,
                            epgChannelID: ch.epgChannelID,
                            isFavorite: ch.isFavorite
                        )
                    }
                    loaded[i].providerName = provider.name
                }
                counts[provider.id] = loaded.count
                allChannels.append(contentsOf: loaded)
                DebugLogger.shared.log(
                    "loadChannels: \(typeLabel) \"\(provider.name)\" loaded \(loaded.count) channels",
                    category: .providers
                )
            } catch {
                errors.append("\(provider.name): \(error.localizedDescription)")
                DebugLogger.shared.log(
                    "loadChannels: \(typeLabel) \"\(provider.name)\" FAILED — \(String(describing: error))",
                    category: .providers
                )
            }
        }
        channelCountByProvider = counts
        DebugLogger.shared.log(
            "loadChannels: done — \(allChannels.count) channels from \(counts.count)/\(enabled.count) providers, \(errors.count) failed",
            category: .providers
        )

        if !errors.isEmpty {
            self.error = errors.joined(separator: "\n")
        }

        // Deduplicate channels — first provider wins when IDs collide
        // (e.g. user added the same provider twice)
        var seenIDs = Set<String>()
        allChannels = allChannels.filter { seenIDs.insert($0.id).inserted }

        // Restore favorites on full channel set
        favoriteOrder = await loadFavoriteOrder()
        let favoriteSet = Set(favoriteOrder)
        providerRawChannels = allChannels.map { channel in
            var c = channel
            c.isFavorite = favoriteSet.contains(c.id)
            return c
        }

        // Merge custom playlist channels into the pipeline
        appendCustomPlaylistChannels()

        await reconcileGroupPreferences()
        applyGroupFilter()
        isLoading = false

        // Match SiriusXM channels to xmplaylist stations for track metadata
        SXMMetadataService.shared.matchChannels(channels)

        // Match sports channels to ESPN scoreboard for live scores
        ESPNScoreService.shared.matchChannels(channels)
    }

    /// Wraps `loadChannels(from:)` with a bounded retry. Cold CarPlay
    /// background launches can fail the first network attempt (DNS, TLS
    /// handshake, or transient connectivity), and XC's three sequential
    /// calls magnify that risk. Retries any thrown error once with a
    /// short backoff so a single dropped request doesn't leave the
    /// provider with zero channels until the next manual refresh.
    private func loadChannelsWithRetry(from provider: Provider, attempts: Int) async throws -> [Channel] {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await loadChannels(from: provider)
            } catch {
                lastError = error
                if attempt < attempts {
                    DebugLogger.shared.log(
                        "loadChannels[\(provider.name)]: attempt \(attempt)/\(attempts) failed (\(String(describing: error))) — retrying",
                        category: .providers
                    )
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        throw lastError ?? NSError(domain: "ProviderManager", code: -1)
    }

    public func loadChannels(from provider: Provider) async throws -> [Channel] {
        switch provider.type {
        case .m3u(let url, let epgURL):
            DebugLogger.shared.log("M3U[\(provider.name)]: fetching playlist", category: .providers)
            let channels = try await M3UParser.parse(from: url)
            DebugLogger.shared.log(
                "M3U[\(provider.name)]: parsed \(channels.count) channels",
                category: .providers
            )
            if let epgURL {
                do {
                    let epg = try await EPGParser.parse(from: epgURL)
                    await MainActor.run { self.epgData.merge(epg) { _, new in new } }
                } catch {
                    // EPG failure is non-fatal — channels still load
                    await MainActor.run { self.error = "EPG data unavailable: \(error.localizedDescription)" }
                }
            }
            return channels

        case .xtreamCodes(let host, let username, let password):
            var api = XtreamCodesAPI(host: host, username: username, password: password)
            DebugLogger.shared.log("XC[\(provider.name)]: authenticate", category: .providers)
            let authResponse = try await api.authenticate()
            api.applyAuthFormats(authResponse)
            DebugLogger.shared.log("XC[\(provider.name)]: getLiveCategories", category: .providers)
            let categories = try await api.getLiveCategories()
            DebugLogger.shared.log("XC[\(provider.name)]: getLiveStreams", category: .providers)
            let streams = try await api.getLiveStreams()
            DebugLogger.shared.log(
                "XC[\(provider.name)]: fetched \(streams.count) streams across \(categories.count) categories",
                category: .providers
            )

            // Load EPG in background — non-fatal, mirrors M3U behavior
            if let xmltvURL = api.xmltvURL {
                Task {
                    do {
                        let epg = try await EPGParser.parse(from: xmltvURL)
                        await MainActor.run { self.epgData.merge(epg) { _, new in new } }
                    } catch {
                        // EPG failure is non-fatal
                    }
                }
            }

            return api.convertToChannels(streams: streams, categories: categories)

        case .subsonic:
            // TODO(E2): load Navidrome library separately from the channels pipeline.
            // Subsonic contributes no channels to the live pipeline in E1; library
            // loading (artists, albums, songs) is deferred to E2. Returning [] is
            // correct — it is NOT an error, and the 0-channels guard in addProvider/
            // updateProvider is intentionally bypassed for Subsonic providers.
            return []

        case .audiobookshelf:
            // Audiobookshelf contributes no live channels — same as Subsonic.
            // Library (audiobooks/chapters) loading is a later epic. Returning []
            // is correct and the 0-channels guard is bypassed for ABS in
            // validateProvider above.
            return []
        }
    }

    // MARK: - Custom Playlist Integration

    private func appendCustomPlaylistChannels() {
        let favoriteSet = Set(favoriteOrder)
        var seenIDs = Set(providerRawChannels.map(\.id))
        var customChannels: [Channel] = []

        for playlist in CustomPlaylistManager.shared.playlists {
            for group in playlist.groups {
                for entry in group.entries {
                    let channel = entry.asChannel(groupName: group.name, playlistName: playlist.name)
                    guard seenIDs.insert(channel.id).inserted else { continue }
                    var c = channel
                    c.isFavorite = favoriteSet.contains(c.id)
                    customChannels.append(c)
                }
            }
        }

        rawChannels = providerRawChannels + customChannels

        // Compute all group counts (including disabled groups) for management UI
        let grouped = Dictionary(grouping: rawChannels, by: \.group)
        allGroupCounts = grouped.mapValues(\.count)

        // Auto-enable new custom playlist groups
        if let enabled = enabledGroups {
            let newGroups = Set(customChannels.map(\.group)).subtracting(enabled)
            if !newGroups.isEmpty {
                enabledGroups = enabled.union(newGroups)
            }
        }
    }

    private func rebuildWithCustomPlaylists() {
        appendCustomPlaylistChannels()
        applyGroupFilter()
    }

    // MARK: - Favorites

    /// Patches `isFavorite` across all three parallel channel arrays
    /// (`channels` / `rawChannels` / `providerRawChannels`) for one channel ID.
    /// Does not touch `favoriteOrder` — callers handle that themselves since
    /// each call site's ordering semantics differ (beads_mobilemusic-t96.10).
    private func setFavorite(_ isFavorite: Bool, forChannelID id: String) {
        if let index = channels.firstIndex(where: { $0.id == id }) {
            channels[index].isFavorite = isFavorite
        }
        if let rawIndex = rawChannels.firstIndex(where: { $0.id == id }) {
            rawChannels[rawIndex].isFavorite = isFavorite
        }
        if let provIndex = providerRawChannels.firstIndex(where: { $0.id == id }) {
            providerRawChannels[provIndex].isFavorite = isFavorite
        }
    }

    public func toggleFavorite(_ channel: Channel) async {
        let newValue: Bool
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            newValue = !channels[index].isFavorite
        } else { return }

        setFavorite(newValue, forChannelID: channel.id)

        if newValue {
            favoriteOrder.append(channel.id)
        } else {
            favoriteOrder.removeAll { $0 == channel.id }
        }
        await saveFavoriteOrder()
        rebuildVisibleGroups()
    }

    public var favoriteChannels: [Channel] {
        let channelMap = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let result = favoriteOrder.compactMap { channelMap[$0] }
        // Deduplicate by stream URL — account channels take priority over custom playlist channels
        var urlToIndex: [URL: Int] = [:]
        var deduped: [Channel] = []
        for channel in result {
            if let idx = urlToIndex[channel.streamURL] {
                if deduped[idx].isCustomPlaylist && !channel.isCustomPlaylist {
                    deduped[idx] = channel
                }
            } else {
                urlToIndex[channel.streamURL] = deduped.count
                deduped.append(channel)
            }
        }
        return deduped
    }

    public func clearFavorites() async {
        for id in favoriteOrder {
            setFavorite(false, forChannelID: id)
        }
        favoriteOrder = []
        await saveFavoriteOrder()
        rebuildVisibleGroups()
    }

    public func moveFavorite(from source: IndexSet, to destination: Int) {
        favoriteOrder.move(fromOffsets: source, toOffset: destination)
        Task { await saveFavoriteOrder() }
    }

    public func removeFavorite(at offsets: IndexSet) {
        // Map offsets through deduped favoriteChannels to get the actual channel IDs
        let deduped = favoriteChannels
        let idsToRemove = offsets.compactMap { idx -> String? in
            guard deduped.indices.contains(idx) else { return nil }
            return deduped[idx].id
        }
        for id in idsToRemove {
            favoriteOrder.removeAll { $0 == id }
        }
        for id in idsToRemove {
            setFavorite(false, forChannelID: id)
        }
        rebuildVisibleGroups()
        Task { await saveFavoriteOrder() }
    }

    private func loadFavoriteOrder() async -> [String] {
        // Try loading as ordered array first
        let order: [String] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.favorites, default: []
        )
        if !order.isEmpty { return order }

        // Migration: load legacy Set<String> and convert to array
        let legacySet: Set<String> = await persistence.loadOrDefault(
            from: Constants.StorageKeys.favorites, default: []
        )
        if !legacySet.isEmpty {
            let migrated = Array(legacySet)
            do {
                try await persistence.save(migrated, to: Constants.StorageKeys.favorites)
            } catch {}
            return migrated
        }

        return []
    }

    private func saveFavoriteOrder() async {
        do {
            try await persistence.save(favoriteOrder, to: Constants.StorageKeys.favorites)
        } catch {
            self.error = "Failed to save favorites: \(error.localizedDescription)"
        }
    }

    // MARK: - Group Filtering & Favorites

    public var visibleChannels: [Channel] { channels }

    private func applyGroupFilter() {
        if let enabled = enabledGroups {
            channels = rawChannels.filter { enabled.contains($0.group) }
        } else {
            channels = rawChannels
        }
        rebuildVisibleGroups()
    }

    public func rebuildVisibleGroups() {
        let groupKeyPath: KeyPath<Channel, String>
        switch channelGroupingMode {
        case .allGroups:
            groupKeyPath = \.group
        case .byProvider:
            groupKeyPath = \.providerGroupKey
        case .bySource:
            groupKeyPath = \.sourceGroupKey
        }
        let grouped = Dictionary(grouping: channels, by: { $0[keyPath: groupKeyPath] })
        let favOrder = favoriteGroupOrder
        let chanSort = channelSortOrder
        let grpSort = groupSortOrder

        // Build first-seen index for provider order of groups
        var groupFirstIndex: [String: Int] = [:]
        for (index, channel) in channels.enumerated() {
            if groupFirstIndex[channel.group] == nil {
                groupFirstIndex[channel.group] = index
            }
        }

        sortedVisibleGroups = grouped.map { name, chans in
            let sortedChans: [Channel]
            switch chanSort {
            case .providerOrder:
                sortedChans = chans
            case .natural:
                sortedChans = chans.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .alphabetical:
                sortedChans = chans.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            return ChannelGroup(name: name, channels: sortedChans, isFavorite: favOrder.contains(name))
        }
        .sorted { a, b in
            let aFav = favOrder.firstIndex(of: a.name)
            let bFav = favOrder.firstIndex(of: b.name)
            switch (aFav, bFav) {
            case let (.some(ai), .some(bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                switch grpSort {
                case .providerOrder:
                    return (groupFirstIndex[a.name] ?? Int.max) < (groupFirstIndex[b.name] ?? Int.max)
                case .natural:
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                case .alphabetical:
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
        }
    }

    public func isGroupEnabled(_ group: String) -> Bool {
        guard let enabled = enabledGroups else { return true }
        return enabled.contains(group)
    }

    public func toggleGroupEnabled(_ group: String) async {
        let allGroups = Set(rawChannels.map(\.group))
        if var enabled = enabledGroups {
            if enabled.contains(group) {
                enabled.remove(group)
            } else {
                enabled.insert(group)
            }
            enabledGroups = enabled == allGroups ? nil : enabled
        } else {
            // First disable: transition from nil (all enabled) to explicit set minus this group
            var enabled = allGroups
            enabled.remove(group)
            enabledGroups = enabled
        }
        await saveEnabledGroups()
        applyGroupFilter()
    }

    public func setAllGroupsEnabled(_ enabled: Bool) async {
        if enabled {
            enabledGroups = nil
        } else {
            enabledGroups = []
        }
        await saveEnabledGroups()
        applyGroupFilter()
    }

    public func isGroupFavorite(_ group: String) -> Bool {
        favoriteGroupOrder.contains(group)
    }

    public func toggleGroupFavorite(_ group: String) async {
        if let index = favoriteGroupOrder.firstIndex(of: group) {
            favoriteGroupOrder.remove(at: index)
        } else {
            favoriteGroupOrder.append(group)
        }
        await saveFavoriteGroupOrder()
        rebuildVisibleGroups()
    }

    public func moveGroupFavorite(from source: IndexSet, to destination: Int) {
        favoriteGroupOrder.move(fromOffsets: source, toOffset: destination)
        rebuildVisibleGroups()
        Task { await saveFavoriteGroupOrder() }
    }

    private func reconcileGroupPreferences() async {
        let allGroups = Set(rawChannels.map(\.group))
        guard !allGroups.isEmpty else { return }

        // Load persisted state
        var loaded: Set<String>? = await loadEnabledGroups()
        var favOrder: [String] = await loadFavoriteGroupOrder()

        // Reconcile enabled groups: only prune stale groups that no longer exist
        if var enabled = loaded {
            let stale = enabled.subtracting(allGroups)
            enabled = enabled.subtracting(stale)
            // If all groups are now enabled, reset to nil
            loaded = enabled == allGroups ? nil : enabled
        }

        // Prune stale favorite groups
        favOrder = favOrder.filter { allGroups.contains($0) }

        enabledGroups = loaded
        favoriteGroupOrder = favOrder
        await saveEnabledGroups()
        await saveFavoriteGroupOrder()
    }

    private func saveEnabledGroups() async {
        do {
            if let enabled = enabledGroups {
                try await persistence.save(Array(enabled), to: Constants.StorageKeys.enabledGroups)
            } else {
                await persistence.delete(Constants.StorageKeys.enabledGroups)
            }
        } catch {
            self.error = "Failed to save group preferences: \(error.localizedDescription)"
        }
    }

    private func loadEnabledGroups() async -> Set<String>? {
        let fileExists = await persistence.fileExists(Constants.StorageKeys.enabledGroups)
        guard fileExists else { return nil }
        let arr: [String] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.enabledGroups, default: []
        )
        // Empty set means corrupted data — treat as nil (all enabled)
        guard !arr.isEmpty else {
            await persistence.delete(Constants.StorageKeys.enabledGroups)
            return nil
        }
        return Set(arr)
    }

    private func saveFavoriteGroupOrder() async {
        do {
            try await persistence.save(favoriteGroupOrder, to: Constants.StorageKeys.favoriteGroups)
        } catch {
            self.error = "Failed to save group favorites: \(error.localizedDescription)"
        }
    }

    private func loadFavoriteGroupOrder() async -> [String] {
        await persistence.loadOrDefault(from: Constants.StorageKeys.favoriteGroups, default: [])
    }
}
