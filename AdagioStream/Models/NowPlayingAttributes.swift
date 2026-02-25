import ActivityKit
import Foundation

struct NowPlayingAttributes: ActivityAttributes {
    let channelName: String
    let channelGroup: String
    let channelID: String

    struct ContentState: Codable, Hashable {
        enum PlaybackState: String, Codable, Hashable {
            case playing
            case buffering
            case paused
        }

        var playbackState: PlaybackState
        var artworkData: Data?
    }
}
