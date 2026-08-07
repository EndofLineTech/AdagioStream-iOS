import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A single channel (radio or TV stream) belonging to a `Provider` or
/// `CustomPlaylist`.
public struct Channel: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let streamURL: URL
    public let logoURL: URL?
    public let group: String
    public let epgChannelID: String?
    public var isFavorite: Bool
    public var providerName: String?
    public var isCustomPlaylist: Bool

    /// Memberwise initializer. All defaults match pre-extraction iOS values
    /// to preserve existing Codable shape.
    public init(
        id: String,
        name: String,
        streamURL: URL,
        logoURL: URL? = nil,
        group: String = "Uncategorized",
        epgChannelID: String? = nil,
        isFavorite: Bool = false,
        providerName: String? = nil,
        isCustomPlaylist: Bool = false
    ) {
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

    /// Tolerant decoder — every recently-added field is `decodeIfPresent`
    /// so older on-disk data still loads.
    public init(from decoder: Decoder) throws {
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

    /// Group key used when grouping channels by provider.
    public var providerGroupKey: String {
        providerName ?? "Unknown Provider"
    }

    /// Group key used when grouping channels by source (provider × group pair).
    public var sourceGroupKey: String {
        let provider = providerName ?? "Unknown"
        return "\(provider) — \(group)"
    }
}

extension Channel: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .channel)
        ProxyRepresentation(exporting: \.name)
    }
}

extension UTType {
    /// Adagio Stream's exported UTI for cross-process drag-and-drop /
    /// share-sheet payloads.
    public static let channel = UTType(exportedAs: "com.adagiostream.channel")
}
