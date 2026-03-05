import Foundation

enum Constants {
    static let appName = "Adagio Stream"
    static let defaultBufferDuration: TimeInterval = 2.0

    enum StorageKeys {
        static let providers = "providers.json"
        static let favorites = "favorites.json"
        static let settings = "settings.json"
        static let enabledGroups = "enabledGroups.json"
        static let favoriteGroups = "favoriteGroups.json"
    }

    enum TimeShift {
        static let maxDuration: TimeInterval = 120
        static let minBytes: Int = 4096
    }

    enum XtreamCodes {
        static let apiPath = "/player_api.php"
        static let livePath = "/live"
        static let defaultStreamExtension = "ts"
    }
}
