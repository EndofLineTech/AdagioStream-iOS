import Foundation

// MARK: - NowPlayingItem Protocol

/// A single item the player can present in the Now Playing / mini-player UI.
///
/// Both live radio (`Channel`) and on-demand tracks (`Track`) conform to this
/// protocol so that the UI can display them through a single surface, regardless
/// of playback mode.
public protocol NowPlayingItem {
    /// Primary display text (channel name or track title).
    var displayTitle: String { get }
    /// Secondary display text, if available (channel group or artist name).
    var displaySubtitle: String? { get }
    /// Optional artwork URL for the item.
    var artworkURL: URL? { get }
    /// True for live-stream items that cannot be seeked.
    var isLiveStream: Bool { get }
}

// MARK: - Channel conformance

extension Channel: NowPlayingItem {
    public var displayTitle: String    { name }
    public var displaySubtitle: String? { group.isEmpty ? nil : group }
    public var artworkURL: URL?        { logoURL }
    public var isLiveStream: Bool      { true }
}

// MARK: - Track conformance

extension Track: NowPlayingItem {
    public var displayTitle: String    { title }
    /// The denormalised artist name (`Track.artist`, c2o), or nil when absent
    /// (e.g. rows cached before the column existed).  Never the raw `artistId` —
    /// that opaque id must not surface in the UI (bug hzl).
    public var displaySubtitle: String? {
        guard let artist, !artist.isEmpty else { return nil }
        return artist
    }
    /// Phase 1: Track artwork is resolved via a Navidrome cover-art URL that
    /// requires a base URL the model does not own.  Return nil here; d6q.2 will
    /// provide a proper resolved URL.
    public var artworkURL: URL?        { nil }
    public var isLiveStream: Bool      { false }
}

// MARK: - PlaybackSource Enum

/// Describes what the player is currently playing or was most recently playing.
///
/// Phase 1 (this bead): only `.radio` is ever assigned; `.library` is defined
/// here as the foundation for d6q.2 (queue-based playback).
public enum PlaybackSource {
    /// Live radio / channel stream.
    case radio(Channel)
    /// On-demand library queue.  `index` is the index of the active track
    /// within `queue`.
    case library(queue: [Track], index: Int)

    /// The item currently being presented by this source.
    public var currentItem: any NowPlayingItem {
        switch self {
        case .radio(let channel):
            return channel
        case .library(let queue, let index):
            return queue[index]
        }
    }
}
