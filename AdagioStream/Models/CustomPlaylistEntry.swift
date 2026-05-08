import Foundation

/// A single entry inside a `CustomPlaylistGroup`. Carries enough data to
/// reconstitute a `Channel` for browse/playback while remaining
/// independent of the underlying provider.
public struct CustomPlaylistEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var streamURL: URL
    public var logoURL: URL?
    public var sourceChannelID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        streamURL: URL,
        logoURL: URL? = nil,
        sourceChannelID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.sourceChannelID = sourceChannelID
    }

    /// Convenience initializer for capturing an existing channel into a
    /// playlist entry — preserves stream + logo URLs.
    public init(channel: Channel) {
        self.id = UUID()
        self.name = channel.name
        self.streamURL = channel.streamURL
        self.logoURL = channel.logoURL
        self.sourceChannelID = channel.id
    }

    /// Renders this entry as a `Channel` for display in the unified browse UI.
    public var asChannel: Channel {
        asChannel(groupName: "Custom", playlistName: nil)
    }

    /// Renders this entry as a `Channel` with caller-specified group +
    /// owning-playlist labels.
    public func asChannel(groupName: String, playlistName: String?) -> Channel {
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
