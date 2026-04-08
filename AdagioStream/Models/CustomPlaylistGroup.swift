import Foundation

struct CustomPlaylistGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var entries: [CustomPlaylistEntry]

    init(id: UUID = UUID(), name: String, entries: [CustomPlaylistEntry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}
