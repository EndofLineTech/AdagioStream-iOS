import Foundation

/// Typed record of the most recent thing the user played, across every
/// playback source (beads_mobilemusic-cpr kickback — CarPlay reconnect
/// resume's "last played" option must resume the previously playing ITEM,
/// not just radio channels).
///
/// Written at each of the three play funnels:
///   - `AudioPlayerService.play(channel:)`
///   - `AudioPlayerService+Audiobook.playAudiobook(_:via:startGlobalTime:)`
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

    private static let storageKey = "lastPlayedItem"

    public static func load() -> LastPlayedItem? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LastPlayedItem.self, from: data)
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
