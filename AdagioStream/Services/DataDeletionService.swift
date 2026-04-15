import Foundation

extension Notification.Name {
    static let didDeleteAllData = Notification.Name("didDeleteAllData")
}

struct DataDeletionService {
    static func deleteAllData() async {
        // 1. Keychain — provider credentials
        KeychainService.delete(for: Constants.StorageKeys.providers)

        // 2. App Support files — all JSON data
        let persistence = PersistenceService.shared
        for key in [
            Constants.StorageKeys.providers,
            Constants.StorageKeys.favorites,
            Constants.StorageKeys.settings,
            Constants.StorageKeys.enabledGroups,
            Constants.StorageKeys.favoriteGroups,
            Constants.StorageKeys.savedSongs,
            Constants.StorageKeys.customPlaylists
        ] {
            await persistence.delete(key)
        }

        // 3. Image cache
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("AdagioStream/image-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)

        // 4. Debug logs
        DebugLogger.shared.clearLogs()

        // 5. UserDefaults — standard
        UserDefaults.standard.removeObject(forKey: "lastPlayedChannelID")

        // 6. UserDefaults — app group
        if let groupDefaults = UserDefaults(suiteName: "group.com.adagiostream.app") {
            groupDefaults.removeObject(forKey: "pendingSharedURLs")
        }

        // 7. Time-shift temp files
        let tempDir = FileManager.default.temporaryDirectory
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in tempFiles where file.pathExtension == "tmp" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
