import Foundation

/// Typed record of the most recent thing the user played, across every
/// playback source (beads_mobilemusic-cpr kickback — CarPlay reconnect
/// resume's "last played" option must resume the previously playing ITEM,
/// not just radio channels).
///
/// Written at each of the four play funnels:
///   - `AudioPlayerService.play(channel:)`
///   - `AudioPlayerService+Audiobook.playAudiobook(_:via:startGlobalTime:)`
///   - `AudioPlayerService+Audiobook.playPodcastEpisode(_:via:context:startGlobalTime:)`
///   - `AudioPlayerService+Queue.startLibraryTrack(_:inQueue:at:via:)`
/// and read only by `CarPlayTemplateManager.resolveCarPlayResumeTarget()`.
///
/// Persisted directly to UserDefaults as JSON — mirrors the pre-existing
/// `lastPlayedChannelID` key's write-on-every-play pattern rather than
/// routing through `AppSettings`/`PersistenceService`, which is for
/// user-configurable settings, not a last-played breadcrumb.
public enum LastPlayedItem: Codable, Equatable {
    case channel(id: String, providerName: String?)
    case audiobook(id: String)
    case libraryTrack(id: String, albumId: String)
    case podcastEpisode(showId: String, episodeId: String)

    private static let storageKey = "lastPlayedItem"

    /// Test seam (cpr kickback round 2, Fix 3): overridden in tests to a
    /// dedicated suite so reads/writes here don't touch real app state or
    /// leak between tests. Production always uses `.standard`.
    static var defaults: UserDefaults = .standard

    public static func load() -> LastPlayedItem? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LastPlayedItem.self, from: data)
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: Self.storageKey)
    }

    public static func clear() {
        defaults.removeObject(forKey: storageKey)
    }
}
