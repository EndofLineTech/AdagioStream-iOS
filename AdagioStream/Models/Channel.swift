import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct Channel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let group: String
    let epgChannelID: String?
    var isFavorite: Bool
    var providerName: String?
    var isCustomPlaylist: Bool

    init(id: String, name: String, streamURL: URL, logoURL: URL? = nil, group: String = "Uncategorized", epgChannelID: String? = nil, isFavorite: Bool = false, providerName: String? = nil, isCustomPlaylist: Bool = false) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.group = group
        self.epgChannelID = epgChannelID
        self.isFavorite = isFavorite
        self.providerName = providerName
        self.isCustomPlaylist = isCustomPlaylist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        streamURL = try container.decode(URL.self, forKey: .streamURL)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        group = try container.decode(String.self, forKey: .group)
        epgChannelID = try container.decodeIfPresent(String.self, forKey: .epgChannelID)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        isCustomPlaylist = try container.decodeIfPresent(Bool.self, forKey: .isCustomPlaylist) ?? false
    }

    var providerGroupKey: String {
        providerName ?? "Unknown Provider"
    }

    var sourceGroupKey: String {
        let provider = providerName ?? "Unknown"
        return "\(provider) — \(group)"
    }
}

extension Channel: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .channel)
        ProxyRepresentation(exporting: \.name)
    }
}

extension UTType {
    static let channel = UTType(exportedAs: "com.adagiostream.channel")
}
