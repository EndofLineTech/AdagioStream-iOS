import Foundation

/// A user-curated playlist of channels grouped into one or more
/// `CustomPlaylistGroup`s. Persisted to disk under
/// `Constants.StorageKeys.customPlaylists`.
public struct CustomPlaylist: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var groups: [CustomPlaylistGroup]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        groups: [CustomPlaylistGroup] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.groups = groups
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
