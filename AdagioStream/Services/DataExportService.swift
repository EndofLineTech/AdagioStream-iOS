import Foundation

public struct DataExportService {
    public struct ExportedData: Codable {
        public let exportDate: Date
        public let appVersion: String
        public let providers: [ExportedProvider]
        public let favorites: [String]
        public let savedSongs: [SavedSong]
        public let customPlaylists: [CustomPlaylist]
        public let favoriteGroups: [String]
        public let enabledGroups: [String]?
        public let settings: AppSettings
    }

    public struct ExportedProvider: Codable {
        public let name: String
        public let type: String
        public let isEnabled: Bool
        public let serverURL: String?
        public let username: String?
    }

    @MainActor
    public static func exportAll(providerManager: ProviderManager, persistence: PersistenceService) async -> ExportedData {
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

    public static func writeExportFile(_ data: ExportedData) throws -> URL {
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
