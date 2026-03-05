import Foundation

// MARK: - App-facing models

struct SXMTrack: Equatable {
    let id: String
    let title: String
    let artists: [String]
    let artworkURL: URL?

    var artistDisplay: String {
        artists.joined(separator: ", ")
    }
}

// MARK: - API response models

struct SXMStation: Decodable {
    let id: String
    let name: String
    let number: Int?
    let deeplink: String
    let genres: [String]?
}

struct SXMStationListResponse: Decodable {
    let count: Int?
    let results: [SXMStation]
}

struct SXMTrackEntry: Decodable {
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

    func toSXMTrack() -> SXMTrack {
        SXMTrack(
            id: track.id ?? UUID().uuidString,
            title: track.title,
            artists: track.artists,
            artworkURL: spotify?.bestImageURL
        )
    }
}

struct SXMStationTracksResponse: Decodable {
    let results: [SXMTrackEntry]
}
