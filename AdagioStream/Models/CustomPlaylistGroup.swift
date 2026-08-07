import Foundation

/// A named group of `CustomPlaylistEntry` items inside a
/// `CustomPlaylist`. Persisted as part of the parent playlist.
public struct CustomPlaylistGroup: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var entries: [CustomPlaylistEntry]

    public init(id: UUID = UUID(), name: String, entries: [CustomPlaylistEntry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}
