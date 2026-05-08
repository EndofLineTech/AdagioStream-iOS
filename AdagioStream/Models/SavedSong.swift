import Foundation

/// A track the user has flagged as "saved" — captured from the SXM
/// metadata stream alongside channel context. Persisted to disk under
/// `Constants.StorageKeys.savedSongs`.
public struct SavedSong: Codable, Identifiable, Equatable {
    public let id: UUID
    public let trackID: String
    public let title: String
    public let artists: [String]
    public let artworkURLString: String?
    public let channelName: String
    public let channelLogoURLString: String?
    public let savedAt: Date

    public init(
        id: UUID = UUID(),
        trackID: String,
        title: String,
        artists: [String],
        artworkURLString: String?,
        channelName: String,
        channelLogoURLString: String?,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.trackID = trackID
        self.title = title
        self.artists = artists
        self.artworkURLString = artworkURLString
        self.channelName = channelName
        self.channelLogoURLString = channelLogoURLString
        self.savedAt = savedAt
    }

    public var artistDisplay: String {
        artists.joined(separator: ", ")
    }

    public var artworkURL: URL? {
        artworkURLString.flatMap { URL(string: $0) }
    }

    public var channelLogoURL: URL? {
        channelLogoURLString.flatMap { URL(string: $0) }
    }

    /// Convenience initializer that captures a track + channel pair into a
    /// new `SavedSong` with a fresh UUID and `savedAt = now`.
    public init(track: SXMTrack, channel: Channel?) {
        self.id = UUID()
        self.trackID = track.id
        self.title = track.title
        self.artists = track.artists
        self.artworkURLString = track.artworkURL?.absoluteString
        self.channelName = channel?.name ?? "Unknown"
        self.channelLogoURLString = channel?.logoURL?.absoluteString
        self.savedAt = Date()
    }
}
