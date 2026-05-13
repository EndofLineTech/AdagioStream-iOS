import Foundation

/// App-wide constants shared between the iOS and tvOS Adagio Stream apps.
///
/// `StorageKeys` strings are byte-identical to the pre-extraction iOS
/// values — they are on-disk filenames AND keychain account keys; renaming
/// any of them silently orphans existing user data.
public enum Constants {
    /// Display name used in user-facing strings.
    public static let appName = "Adagio Stream"

    /// Default audio buffer length in seconds.
    public static let defaultBufferDuration: TimeInterval = 5.0
    /// Old default kept only so the one-time migration in SettingsViewModel
    /// can recognize unmodified-from-old-default values and bump them up.
    public static let legacyDefaultBufferDuration: TimeInterval = 2.0

    /// Filenames in app-support storage and account keys in the Keychain.
    /// Do NOT rename these — they identify persisted user data.
    public enum StorageKeys {
        public static let providers = "providers.json"
        public static let favorites = "favorites.json"
        public static let settings = "settings.json"
        public static let enabledGroups = "enabledGroups.json"
        public static let favoriteGroups = "favoriteGroups.json"
        public static let savedSongs = "savedSongs.json"
        public static let customPlaylists = "customPlaylists.json"
    }

    /// Time-shift buffer tunables.
    public enum TimeShift {
        public static let maxDuration: TimeInterval = 120
        public static let minBytes: Int = 4096
    }

    /// Xtream Codes provider URL conventions.
    public enum XtreamCodes {
        public static let apiPath = "/player_api.php"
        public static let livePath = "/live"
        public static let defaultStreamExtension = "ts"
    }
}
