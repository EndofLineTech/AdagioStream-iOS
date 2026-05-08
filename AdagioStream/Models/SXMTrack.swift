import Foundation

// MARK: - App-facing models

/// SiriusXM track metadata as exposed to the app's UI.
public struct SXMTrack: Equatable {
    public let id: String
    public let title: String
    public let artists: [String]
    public let artworkURL: URL?
    public let startedAt: Date?

    public init(
        id: String,
        title: String,
        artists: [String],
        artworkURL: URL?,
        startedAt: Date?
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.artworkURL = artworkURL
        self.startedAt = startedAt
    }

    public var artistDisplay: String {
        artists.joined(separator: ", ")
    }
}

// MARK: - API response models

/// One SXM station record returned by the third-party metadata service.
public struct SXMStation: Decodable {
    public let id: String
    public let name: String
    public let number: String?
    public let deeplink: String
    public let genres: [String]?
}

public struct SXMStationListResponse: Decodable {
    public let count: Int?
    public let results: [SXMStation]
}

public struct SXMTrackEntry: Decodable {
    public let timestamp: String?
    public let track: TrackInfo
    public let spotify: SpotifyInfo?

    public struct TrackInfo: Decodable {
        public let id: String?
        public let title: String
        public let artists: [String]
    }

    public struct SpotifyInfo: Decodable {
        public let albumImageLarge: String?
        public let albumImageMedium: String?
        public let albumImageSmall: String?

        public var bestImageURL: URL? {
            let urlString = albumImageLarge ?? albumImageMedium ?? albumImageSmall
            return urlString.flatMap { URL(string: $0) }
        }
    }

    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func toSXMTrack() -> SXMTrack {
        SXMTrack(
            id: track.id ?? UUID().uuidString,
            title: track.title,
            artists: track.artists,
            artworkURL: spotify?.bestImageURL,
            startedAt: timestamp.flatMap { Self.iso8601.date(from: $0) }
        )
    }
}

public struct SXMStationTracksResponse: Decodable {
    public let results: [SXMTrackEntry]
}

// MARK: - Feed API models

public struct SXMFeedEntry: Decodable {
    public let channelId: String
    public let timestamp: String?
    public let track: SXMTrackEntry.TrackInfo
    public let spotify: SXMTrackEntry.SpotifyInfo?

    public func toSXMTrack() -> SXMTrack {
        SXMTrack(
            id: track.id ?? UUID().uuidString,
            title: track.title,
            artists: track.artists,
            artworkURL: spotify?.bestImageURL,
            startedAt: timestamp.flatMap { SXMTrackEntry.iso8601.date(from: $0) }
        )
    }
}

public struct SXMFeedResponse: Decodable {
    public let count: Int?
    public let results: [SXMFeedEntry]
}
