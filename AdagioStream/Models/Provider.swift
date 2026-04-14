import Foundation

struct Provider: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: ProviderType
    var isEnabled: Bool
    var stripStreamIDs: Bool

    init(id: UUID = UUID(), name: String, type: ProviderType, isEnabled: Bool = true, stripStreamIDs: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.isEnabled = isEnabled
        self.stripStreamIDs = stripStreamIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(ProviderType.self, forKey: .type)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        stripStreamIDs = try container.decodeIfPresent(Bool.self, forKey: .stripStreamIDs) ?? false
    }

    enum ProviderType: Codable, Hashable {
        case m3u(url: URL, epgURL: URL?)
        case xtreamCodes(host: URL, username: String, password: String)
    }
}
