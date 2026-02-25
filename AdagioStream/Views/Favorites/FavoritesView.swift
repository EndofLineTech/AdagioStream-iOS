import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService

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
                            ChannelRowView(channel: channel) {
                                audioPlayer.channels = providerManager.favoriteChannels
                                audioPlayer.play(channel: channel)
                            } onToggleFavorite: {
                                Task { await providerManager.toggleFavorite(channel) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
