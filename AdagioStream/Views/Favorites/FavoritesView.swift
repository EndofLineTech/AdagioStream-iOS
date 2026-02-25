import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var editMode: EditMode = .inactive

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
                        .onMove { providerManager.moveFavorite(from: $0, to: $1) }
                        .onDelete { providerManager.removeFavorite(at: $0) }
                    }
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .environment(\.editMode, $editMode)
        }
    }
}
