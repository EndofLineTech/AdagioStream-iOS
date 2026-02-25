import Foundation

struct ChannelGroup: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var channels: [Channel]
    var isFavorite: Bool = false

    var count: Int { channels.count }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    static func == (lhs: ChannelGroup, rhs: ChannelGroup) -> Bool {
        lhs.name == rhs.name
    }
}
