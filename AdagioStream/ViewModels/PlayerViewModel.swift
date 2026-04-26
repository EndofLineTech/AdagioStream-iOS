import AdagioStreamCore
import Foundation
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    let audioPlayer: AudioPlayerService
    let providerManager: ProviderManager

    init(audioPlayer: AudioPlayerService, providerManager: ProviderManager) {
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
    }

    var currentEPG: [EPGEntry] {
        guard let channelID = audioPlayer.currentChannel?.epgChannelID else { return [] }
        return providerManager.epgData[channelID]?.sorted(by: { $0.start < $1.start }) ?? []
    }

    var nowPlaying: EPGEntry? {
        currentEPG.first(where: \.isCurrentlyAiring)
    }

    var upNext: EPGEntry? {
        currentEPG.first(where: \.isUpcoming)
    }
}
