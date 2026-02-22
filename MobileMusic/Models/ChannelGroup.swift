import Foundation

struct ChannelGroup: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var channels: [Channel]

    var count: Int { channels.count }
}
