import Foundation

// MARK: - App-facing models

struct SXMTrack: Equatable {
    let id: String
    let title: String
    let artists: [String]
    let artworkURL: URL?
    let startedAt: Date?

    var artistDisplay: String {
        artists.joined(separator: ", ")
    }
}

// MARK: - API response models

struct SXMStation: Decodable {
    let id: String
    let name: String
    let number: String?
    let deeplink: String
    let genres: [String]?
}

struct SXMStationListResponse: Decodable {
    let count: Int?
    let results: [SXMStation]
}

struct SXMTrackEntry: Decodable {
    let timestamp: String?
    let track: TrackInfo
    let spotify: SpotifyInfo?

    struct TrackInfo: Decodable {
        let id: String?
        let title: String
        let artists: [String]
    }

    struct SpotifyInfo: Decodable {
        let albumImageLarge: String?
        let albumImageMedium: String?
        let albumImageSmall: String?

        var bestImageURL: URL? {
            let urlString = albumImageLarge ?? albumImageMedium ?? albumImageSmall
            return urlString.flatMap { URL(string: $0) }
        }
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func toSXMTrack() -> SXMTrack {
        SXMTrack(
            id: track.id ?? UUID().uuidString,
            title: track.title,
            artists: track.artists,
            artworkURL: spotify?.bestImageURL,
            startedAt: timestamp.flatMap { Self.iso8601.date(from: $0) }
        )
    }
}

struct SXMStationTracksResponse: Decodable {
    let results: [SXMTrackEntry]
}

// MARK: - Feed API models

struct SXMFeedEntry: Decodable {
    let channelId: String
    let timestamp: String?
    let track: SXMTrackEntry.TrackInfo
    let spotify: SXMTrackEntry.SpotifyInfo?

    func toSXMTrack() -> SXMTrack {
        SXMTrack(
            id: track.id ?? UUID().uuidString,
            title: track.title,
            artists: track.artists,
            artworkURL: spotify?.bestImageURL,
            startedAt: timestamp.flatMap { SXMTrackEntry.iso8601.date(from: $0) }
        )
    }
}

struct SXMFeedResponse: Decodable {
    let count: Int?
    let results: [SXMFeedEntry]
}
