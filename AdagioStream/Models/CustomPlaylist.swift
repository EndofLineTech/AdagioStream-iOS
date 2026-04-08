import Foundation

struct CustomPlaylist: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var groups: [CustomPlaylistGroup]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, groups: [CustomPlaylistGroup] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.groups = groups
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
