import Foundation

struct SavedSong: Codable, Identifiable, Equatable {
    let id: UUID
    let trackID: String
    let title: String
    let artists: [String]
    let artworkURLString: String?
    let channelName: String
    let channelLogoURLString: String?
    let savedAt: Date

    var artistDisplay: String {
        artists.joined(separator: ", ")
    }

    var artworkURL: URL? {
        artworkURLString.flatMap { URL(string: $0) }
    }

    var channelLogoURL: URL? {
        channelLogoURLString.flatMap { URL(string: $0) }
    }

    init(track: SXMTrack, channel: Channel?) {
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
