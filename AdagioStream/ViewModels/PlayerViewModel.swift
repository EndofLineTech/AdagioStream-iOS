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
