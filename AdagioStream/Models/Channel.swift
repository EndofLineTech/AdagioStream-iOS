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

    init(id: String, name: String, streamURL: URL, logoURL: URL? = nil, group: String = "Uncategorized", epgChannelID: String? = nil, isFavorite: Bool = false, providerName: String? = nil) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.group = group
        self.epgChannelID = epgChannelID
        self.isFavorite = isFavorite
        self.providerName = providerName
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
