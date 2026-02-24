import Foundation

struct Channel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let group: String
    let epgChannelID: String?
    var isFavorite: Bool

    init(id: String, name: String, streamURL: URL, logoURL: URL? = nil, group: String = "Uncategorized", epgChannelID: String? = nil, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.group = group
        self.epgChannelID = epgChannelID
        self.isFavorite = isFavorite
    }
}
