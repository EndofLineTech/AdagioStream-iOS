import Foundation
import SwiftUI

struct NewProviderInfo: Identifiable {
    let id = UUID()
    let providerName: String
    let groupCount: Int
    let channelCount: Int
}

@MainActor
final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    @Published var providers: [Provider] = []
    @Published var newProviderInfo: NewProviderInfo?
    @Published var channels: [Channel] = []
    @Published var epgData: [String: [EPGEntry]] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var collapsedGroups: Set<String> = []
    @Published private(set) var favoriteOrder: [String] = []
    @Published private(set) var enabledGroups: Set<String>? = nil
    @Published private(set) var favoriteGroupOrder: [String] = []
    @Published private(set) var channelCountByProvider: [UUID: Int] = [:]
    @Published private(set) var sortedVisibleGroups: [ChannelGroup] = []
    @Published private(set) var allGroupCounts: [String: Int] = [:]
    @Published var channelSortOrder: ChannelSortOrder = .providerOrder
    @Published var groupSortOrder: ChannelSortOrder = .providerOrder
    @Published var channelGroupingMode: ChannelGroupingMode = .allGroups
    private var rawChannels: [Channel] = []
    private var hasInitializedCollapsedGroups = false
    private var isLoadingChannels = false

    private let persistence = PersistenceService.shared

    init() {
        Task {
            let settings: AppSettings = await persistence.loadOrDefault(
                from: Constants.StorageKeys.settings, default: .default
            )
            channelSortOrder = settings.channelSortOrder
            groupSortOrder = settings.groupSortOrder
            channelGroupingMode = settings.channelGroupingMode
            await loadProviders()
            if !providers.isEmpty {
                await loadChannels()
            }
        }
    }

    func loadProviders() async {
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

    func addProvider(_ provider: Provider) async {
        let existingGroups = Set(rawChannels.map(\.group))

        providers.append(provider)
        await saveProviders()
        await loadChannels()

        // Disable groups that are new from this provider
        let allGroups = Set(rawChannels.map(\.group))
        let newGroups = allGroups.subtracting(existingGroups)

        if !newGroups.isEmpty {
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

    func deleteProvider(_ provider: Provider) async {
        providers.removeAll { $0.id == provider.id }
        await saveProviders()
        if providers.isEmpty {
            rawChannels = []
            channels = []
            epgData = [:]
            allGroupCounts = [:]
            error = nil
        }
    }

    func updateProvider(_ provider: Provider) async {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
            await saveProviders()
        }
    }

    func toggleProviderEnabled(_ provider: Provider) async {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index].isEnabled.toggle()
            await saveProviders()
            await loadChannels()
        }
    }

    var enabledProviderCount: Int {
        providers.filter(\.isEnabled).count
    }

    private func saveProviders() async {
        do {
            let data = try JSONEncoder().encode(providers)
            try KeychainService.save(data, for: Constants.StorageKeys.providers)
        } catch {
            self.error = "Failed to save providers: \(error.localizedDescription)"
        }
    }

    // MARK: - Channel Loading

    func loadChannels() async {
        guard !isLoadingChannels else { return }
        isLoadingChannels = true
        defer { isLoadingChannels = false }
        isLoading = true
        error = nil

        var allChannels: [Channel] = []
        var errors: [String] = []
        var counts: [UUID: Int] = [:]

        for provider in providers.filter(\.isEnabled) {
            do {
                var loaded = try await loadChannels(from: provider)
                for i in loaded.indices {
                    loaded[i].providerName = provider.name
                }
                counts[provider.id] = loaded.count
                allChannels.append(contentsOf: loaded)
            } catch {
                errors.append("\(provider.name): \(error.localizedDescription)")
            }
        }
        channelCountByProvider = counts

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
        rawChannels = allChannels.map { channel in
            var c = channel
            c.isFavorite = favoriteSet.contains(c.id)
            return c
        }

        // Compute all group counts (including disabled groups) for management UI
        let grouped = Dictionary(grouping: rawChannels, by: \.group)
        allGroupCounts = grouped.mapValues(\.count)

        if !hasInitializedCollapsedGroups && !rawChannels.isEmpty {
            collapsedGroups = Set(rawChannels.map(\.group))
            hasInitializedCollapsedGroups = true
        }

        await reconcileGroupPreferences()
        applyGroupFilter()
        isLoading = false

        // Match SiriusXM channels to xmplaylist stations for track metadata
        SXMMetadataService.shared.matchChannels(channels)

        // Match sports channels to ESPN scoreboard for live scores
        ESPNScoreService.shared.matchChannels(channels)
    }

    func loadChannels(from provider: Provider) async throws -> [Channel] {
        switch provider.type {
        case .m3u(let url, let epgURL):
            let channels = try await M3UParser.parse(from: url)
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
            let authResponse = try await api.authenticate()
            api.applyAuthFormats(authResponse)
            let categories = try await api.getLiveCategories()
            let streams = try await api.getLiveStreams()

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
        }
    }

    // MARK: - Favorites

    func toggleFavorite(_ channel: Channel) async {
        let newValue: Bool
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index].isFavorite.toggle()
            newValue = channels[index].isFavorite
        } else { return }

        // Keep rawChannels in sync
        if let rawIndex = rawChannels.firstIndex(where: { $0.id == channel.id }) {
            rawChannels[rawIndex].isFavorite = newValue
        }

        if newValue {
            favoriteOrder.append(channel.id)
        } else {
            favoriteOrder.removeAll { $0 == channel.id }
        }
        await saveFavoriteOrder()
        rebuildVisibleGroups()
    }

    var favoriteChannels: [Channel] {
        let channelMap = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return favoriteOrder.compactMap { channelMap[$0] }
    }

    func clearFavorites() async {
        for i in channels.indices {
            channels[i].isFavorite = false
        }
        for i in rawChannels.indices {
            rawChannels[i].isFavorite = false
        }
        favoriteOrder = []
        await saveFavoriteOrder()
        rebuildVisibleGroups()
    }

    func moveFavorite(from source: IndexSet, to destination: Int) {
        favoriteOrder.move(fromOffsets: source, toOffset: destination)
        Task { await saveFavoriteOrder() }
    }

    func removeFavorite(at offsets: IndexSet) {
        let idsToRemove = offsets.map { favoriteOrder[$0] }
        favoriteOrder.remove(atOffsets: offsets)
        for id in idsToRemove {
            if let index = channels.firstIndex(where: { $0.id == id }) {
                channels[index].isFavorite = false
            }
            if let rawIndex = rawChannels.firstIndex(where: { $0.id == id }) {
                rawChannels[rawIndex].isFavorite = false
            }
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

    var visibleChannels: [Channel] { channels }

    private func applyGroupFilter() {
        if let enabled = enabledGroups {
            channels = rawChannels.filter { enabled.contains($0.group) }
        } else {
            channels = rawChannels
        }
        rebuildVisibleGroups()
    }

    func rebuildVisibleGroups() {
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

    func isGroupEnabled(_ group: String) -> Bool {
        guard let enabled = enabledGroups else { return true }
        return enabled.contains(group)
    }

    func toggleGroupEnabled(_ group: String) async {
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

    func setAllGroupsEnabled(_ enabled: Bool) async {
        if enabled {
            enabledGroups = nil
        } else {
            enabledGroups = []
        }
        await saveEnabledGroups()
        applyGroupFilter()
    }

    func isGroupFavorite(_ group: String) -> Bool {
        favoriteGroupOrder.contains(group)
    }

    func toggleGroupFavorite(_ group: String) async {
        if let index = favoriteGroupOrder.firstIndex(of: group) {
            favoriteGroupOrder.remove(at: index)
        } else {
            favoriteGroupOrder.append(group)
        }
        await saveFavoriteGroupOrder()
        rebuildVisibleGroups()
    }

    func moveGroupFavorite(from source: IndexSet, to destination: Int) {
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
