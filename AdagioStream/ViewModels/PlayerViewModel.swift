// PlayerViewModel depends on AudioPlayerService which is iOS-only per
// Phase 0 G2. Gate the whole file `#if os(iOS)` so the tvOS build sees
// no symbol — tvOS Phase 1 will provide its own player VM as needed.

#if os(iOS)
import Foundation
import SwiftUI

@MainActor
public final class PlayerViewModel: ObservableObject {
    public let audioPlayer: AudioPlayerService
    public let providerManager: ProviderManager

    public init(audioPlayer: AudioPlayerService, providerManager: ProviderManager) {
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
    }

    public var currentEPG: [EPGEntry] {
        guard let channelID = audioPlayer.currentChannel?.epgChannelID else { return [] }
        return providerManager.epgData[channelID]?.sorted(by: { $0.start < $1.start }) ?? []
    }

    public var nowPlaying: EPGEntry? {
        currentEPG.first(where: \.isCurrentlyAiring)
    }

    public var upNext: EPGEntry? {
        currentEPG.first(where: \.isUpcoming)
    }
}

#endif // os(iOS)
