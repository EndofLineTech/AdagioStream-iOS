import Foundation

struct Provider: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: ProviderType

    init(id: UUID = UUID(), name: String, type: ProviderType) {
        self.id = id
        self.name = name
        self.type = type
    }

    enum ProviderType: Codable, Hashable {
        case m3u(url: URL, epgURL: URL?)
        case xtreamCodes(host: URL, username: String, password: String)
    }
}
