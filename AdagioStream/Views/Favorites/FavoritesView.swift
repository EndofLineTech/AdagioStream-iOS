import AdagioStreamCore
import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var sxmService: SXMMetadataService
    @State private var editMode: EditMode = .inactive
    @State private var channelToAdd: Channel?

    var body: some View {
        NavigationStack {
            Group {
                if providerManager.favoriteChannels.isEmpty {
                    EmptyStateView(
                        title: "No Favorites",
                        systemImage: "star",
                        description: "Star channels to add them to your favorites."
                    )
                } else {
                    List {
                        ForEach(providerManager.favoriteChannels) { channel in
                            ChannelRowView(channel: channel, nowPlayingTrack: sxmService.feedTracks[channel.id], espnGame: ESPNScoreService.shared.gamesByChannel[channel.id]) {
                                audioPlayer.channels = providerManager.favoriteChannels
                                audioPlayer.play(channel: channel)
                            } onToggleFavorite: {
                                Task { await providerManager.toggleFavorite(channel) }
                            } onAddToPlaylist: {
                                channelToAdd = channel
                            }
                        }
                        .onMove { providerManager.moveFavorite(from: $0, to: $1) }
                        .onDelete { providerManager.removeFavorite(at: $0) }
                    }
                    .dropDestination(for: Channel.self) { channels, _ in
                        for channel in channels where !channel.isFavorite {
                            Task { await providerManager.toggleFavorite(channel) }
                        }
                        return !channels.isEmpty
                    }
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .environment(\.editMode, $editMode)
            .sheet(item: $channelToAdd) { channel in
                AddToPlaylistSheet(channel: channel)
                    .presentationDetents([.medium])
            }
        }
    }
}
