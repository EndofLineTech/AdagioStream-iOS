import Foundation

enum Constants {
    static let appName = "Adagio Stream"
    static let defaultBufferDuration: TimeInterval = 10.0

    enum StorageKeys {
        static let providers = "providers.json"
        static let favorites = "favorites.json"
        static let settings = "settings.json"
    }

    enum XtreamCodes {
        static let apiPath = "/player_api.php"
        static let livePath = "/live"
        static let defaultStreamExtension = "m3u8"
    }
}
