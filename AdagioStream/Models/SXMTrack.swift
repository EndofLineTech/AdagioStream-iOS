import Foundation

// MARK: - Metadata source selection

/// Which third-party API supplies SiriusXM now-playing metadata.
public enum SXMMetadataSource: String, CaseIterable {
    case xmplaylist
    case stellartunerlog

    public static let defaultsKey = "sxmMetadataSource"

    /// The user-selected source, defaulting to StellarTunerLog when the user
    /// has never chosen. A persisted user choice still wins over the default.
    public static var current: SXMMetadataSource {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(SXMMetadataSource.init(rawValue:)) ?? .stellartunerlog
    }

    public var label: String {
        switch self {
        case .xmplaylist: return "xmplaylist.com"
        case .stellartunerlog: return "StellarTunerLog"
        }
    }
}

/// Foreground tuned-channel now-playing poll interval, in seconds. One shared
/// value across both metadata sources. Readable without SwiftUI so Services
/// (which build for tvOS) can consume it.
public enum SXMPollInterval {
    public static let defaultsKey = "sxmPollIntervalSeconds"
    public static let options: [Int] = [10, 15, 20, 25, 30, 35, 40, 45]
    public static let defaultSeconds = 30

    /// User-selected seconds, clamped to the allowed range so a garbage
    /// default can't produce a runaway timer. Unset → default.
    public static var current: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        let seconds = stored ?? defaultSeconds
        return TimeInterval(min(max(seconds, options.first!), options.last!))
    }
}

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

// MARK: - StellarTunerLog API models (api.stellartunerlog.com/v1)

/// One channel from GET /v1/channels. The catalog is keyed by numeric-string
/// channel id; only the fields the app matches on are decoded.
public struct STLChannel: Decodable {
    public let id: String
    public let name: String
    public let channelNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case channelNumber = "channel_number"
    }
}

public struct STLChannelListResponse: Decodable {
    public let channels: [String: STLChannel]

    enum CodingKeys: String, CodingKey { case channels }

    /// One malformed catalog entry drops instead of failing the whole response.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channels = try container
            .decode([String: STLFailableDecodable<STLChannel>].self, forKey: .channels)
            .compactMapValues(\.value)
    }
}

/// Decodes to nil instead of throwing, so one bad dictionary entry
/// doesn't poison an entire STL response.
struct STLFailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Now-playing state for one station, from /v1/nowplaying[/{id}].
public struct STLStation: Decodable {
    public let id: String
    public let name: String
    public let artist: String
    public let title: String
    public let album: String?
    public let cutType: String
    public let artworkURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, artist, title, album
        case cutType = "cut_type"
        case artworkURL = "artwork_url"
    }

    public init(
        id: String, name: String, artist: String, title: String,
        album: String?, cutType: String, artworkURL: String?
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.title = title
        self.album = album
        self.cutType = cutType
        self.artworkURL = artworkURL
    }

    /// Null/missing-tolerant: artist/title/cutType default to "" so a
    /// degenerate station degrades to "no track" (empty cutType fails the
    /// displayability check) instead of failing the whole response decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album)
        cutType = try container.decodeIfPresent(String.self, forKey: .cutType) ?? ""
        artworkURL = try container.decodeIfPresent(String.self, forKey: .artworkURL)
    }

    /// Cut types that are never program content: Spot/Promo (ads and promos),
    /// Fill (filler), Perm (placeholder where artist == channel name).
    /// Link is NOT hidden: live-feed surveys show it overwhelmingly carries
    /// real program data — DJ mix shows ("@Shallou | #HouseOfChill"), comedy
    /// sets, podcast episodes, Stern segments — and mix/comedy/podcast
    /// channels sit in Link for hours. The rare "Commercials" Link entry
    /// showing through is an accepted cost.
    /// Live vocabulary is wide (Song, Music, talk, sports, Exp, PGM_Segment,
    /// even the typo'd PGM_Segement), so this is a blocklist — anything not
    /// listed here is real metadata and shown.
    private static let hiddenCutTypes: Set<String> = ["spot", "promo", "fill", "perm"]

    /// Whether this cut is real program metadata worth displaying.
    /// Empty/missing cut_type hides too (the xmplaylist "commercial break"
    /// nil-track case).
    public var isDisplayable: Bool {
        let cut = cutType.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cut.isEmpty && !Self.hiddenCutTypes.contains(cut.lowercased())
    }

    /// Stable synthesized track id — the API has no per-track id, so
    /// (station, artist, title) identifies a play for Equatable/history dedupe.
    /// Ceiling: the API is timestamp-less, so a replay within the 10-min
    /// history window dedupes to the first observation and reuses its startedAt.
    public var trackID: String {
        "\(id)|\(artist)|\(title)"
    }

    /// Convert to the app-facing track model. Returns nil for non-displayable
    /// cuts, and for displayable cuts with no artist and no title (nothing to
    /// show). `startedAt` is caller-supplied because the API carries no
    /// per-track timestamp — the service stamps first-observation time.
    public func toSXMTrack(startedAt: Date?) -> SXMTrack? {
        guard isDisplayable else { return nil }
        let hasContent = !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return nil }
        return SXMTrack(
            id: trackID,
            title: title,
            artists: [artist],
            artworkURL: artworkURL.flatMap { URL(string: $0) },
            startedAt: startedAt
        )
    }
}

/// Envelope for GET /v1/nowplaying (all stations, keyed by channel id).
public struct STLNowPlayingResponse: Decodable {
    public let stations: [String: STLStation]

    enum CodingKeys: String, CodingKey { case stations }

    /// One malformed station entry drops instead of failing the whole response.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stations = try container
            .decode([String: STLFailableDecodable<STLStation>].self, forKey: .stations)
            .compactMapValues(\.value)
    }
}

/// Envelope for GET /v1/nowplaying/{channel_id} (single station, no history).
public struct STLStationResponse: Decodable {
    public let station: STLStation
}
