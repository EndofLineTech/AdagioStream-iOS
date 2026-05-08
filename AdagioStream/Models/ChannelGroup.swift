import Foundation

/// In-memory grouping of channels under a single category name. Identity
/// + equality + hash all key off `name`.
public struct ChannelGroup: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public var channels: [Channel]
    public var isFavorite: Bool

    public init(name: String, channels: [Channel], isFavorite: Bool = false) {
        self.name = name
        self.channels = channels
        self.isFavorite = isFavorite
    }

    public var count: Int { channels.count }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    public static func == (lhs: ChannelGroup, rhs: ChannelGroup) -> Bool {
        lhs.name == rhs.name
    }
}
