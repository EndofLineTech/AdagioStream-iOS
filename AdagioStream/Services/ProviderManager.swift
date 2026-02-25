import Foundation
import SwiftUI

@MainActor
final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    @Published var providers: [Provider] = []
    @Published var channels: [Channel] = []
    @Published var epgData: [String: [EPGEntry]] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var collapsedGroups: Set<String> = []
    private var hasInitializedCollapsedGroups = false

    private let persistence = PersistenceService.shared

    init() {
        Task {
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
        providers.append(provider)
        await saveProviders()
        await loadChannels()
    }

    func deleteProvider(_ provider: Provider) async {
        providers.removeAll { $0.id == provider.id }
        await saveProviders()
        // Remove channels that came from this provider
        if providers.isEmpty {
            channels = []
            epgData = [:]
            error = nil
        }
    }

    func updateProvider(_ provider: Provider) async {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
            await saveProviders()
        }
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
        isLoading = true
        error = nil

        var allChannels: [Channel] = []
        var errors: [String] = []

        for provider in providers {
            do {
                let loaded = try await loadChannels(from: provider)
                allChannels.append(contentsOf: loaded)
            } catch {
                errors.append("\(provider.name): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty {
            self.error = errors.joined(separator: "\n")
        }

        // Restore favorites
        let favoriteIDs: Set<String> = await loadFavoriteIDs()
        channels = allChannels.map { channel in
            var c = channel
            c.isFavorite = favoriteIDs.contains(c.id)
            return c
        }

        if !hasInitializedCollapsedGroups && !channels.isEmpty {
            collapsedGroups = Set(channels.map(\.group))
            hasInitializedCollapsedGroups = true
        }

        isLoading = false
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
            return api.convertToChannels(streams: streams, categories: categories)
        }
    }

    // MARK: - Favorites

    func toggleFavorite(_ channel: Channel) async {
        if let index = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[index].isFavorite.toggle()
            await saveFavoriteIDs()
        }
    }

    var favoriteChannels: [Channel] {
        channels.filter(\.isFavorite)
    }

    func clearFavorites() async {
        for i in channels.indices {
            channels[i].isFavorite = false
        }
        await saveFavoriteIDs()
    }

    private func loadFavoriteIDs() async -> Set<String> {
        await persistence.loadOrDefault(from: Constants.StorageKeys.favorites, default: Set<String>())
    }

    private func saveFavoriteIDs() async {
        let ids = Set(channels.filter(\.isFavorite).map(\.id))
        do {
            try await persistence.save(ids, to: Constants.StorageKeys.favorites)
        } catch {
            self.error = "Failed to save favorites: \(error.localizedDescription)"
        }
    }
}
