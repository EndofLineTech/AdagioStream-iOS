import Foundation

struct Provider: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: ProviderType
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, type: ProviderType, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(ProviderType.self, forKey: .type)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    enum ProviderType: Codable, Hashable {
        case m3u(url: URL, epgURL: URL?)
        case xtreamCodes(host: URL, username: String, password: String)
    }
}
