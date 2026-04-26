import AdagioStreamCore
import Foundation

struct DataExportService {
    struct ExportedData: Codable {
        let exportDate: Date
        let appVersion: String
        let providers: [ExportedProvider]
        let favorites: [String]
        let savedSongs: [SavedSong]
        let customPlaylists: [CustomPlaylist]
        let favoriteGroups: [String]
        let enabledGroups: [String]?
        let settings: AppSettings
    }

    struct ExportedProvider: Codable {
        let name: String
        let type: String
        let isEnabled: Bool
        let serverURL: String?
        let username: String?
    }

    @MainActor
    static func exportAll(providerManager: ProviderManager, persistence: PersistenceService) async -> ExportedData {
        let providers = providerManager.providers.map { provider -> ExportedProvider in
            switch provider.type {
            case .m3u(let url, _):
                return ExportedProvider(
                    name: provider.name,
                    type: "M3U",
                    isEnabled: provider.isEnabled,
                    serverURL: url.absoluteString,
                    username: nil
                )
            case .xtreamCodes(let host, let username, _):
                return ExportedProvider(
                    name: provider.name,
                    type: "Xtream Codes",
                    isEnabled: provider.isEnabled,
                    serverURL: host.absoluteString,
                    username: username
                )
            }
        }

        let favorites: [String] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.favorites, default: []
        )
        let savedSongs: [SavedSong] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.savedSongs, default: []
        )
        let customPlaylists: [CustomPlaylist] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.customPlaylists, default: []
        )
        let favoriteGroups: [String] = await persistence.loadOrDefault(
            from: Constants.StorageKeys.favoriteGroups, default: []
        )
        let enabledGroups: Set<String>? = try? await persistence.load(
            from: Constants.StorageKeys.enabledGroups
        )
        let settings: AppSettings = await persistence.loadOrDefault(
            from: Constants.StorageKeys.settings, default: .default
        )

        return ExportedData(
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            providers: providers,
            favorites: favorites,
            savedSongs: savedSongs,
            customPlaylists: customPlaylists,
            favoriteGroups: favoriteGroups,
            enabledGroups: enabledGroups.map(Array.init),
            settings: settings
        )
    }

    static func writeExportFile(_ data: ExportedData) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(data)

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("adagiostream-export.json")
        try json.write(to: fileURL)
        return fileURL
    }
}
