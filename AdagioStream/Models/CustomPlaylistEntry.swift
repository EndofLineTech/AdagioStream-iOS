import Foundation

struct CustomPlaylistEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var streamURL: URL
    var logoURL: URL?
    var sourceChannelID: String?

    init(id: UUID = UUID(), name: String, streamURL: URL, logoURL: URL? = nil, sourceChannelID: String? = nil) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.sourceChannelID = sourceChannelID
    }

    init(channel: Channel) {
        self.id = UUID()
        self.name = channel.name
        self.streamURL = channel.streamURL
        self.logoURL = channel.logoURL
        self.sourceChannelID = channel.id
    }

    var asChannel: Channel {
        asChannel(groupName: "Custom", playlistName: nil)
    }

    func asChannel(groupName: String, playlistName: String?) -> Channel {
        Channel(
            id: id.uuidString,
            name: name,
            streamURL: streamURL,
            logoURL: logoURL,
            group: groupName,
            providerName: playlistName,
            isCustomPlaylist: true
        )
    }
}
