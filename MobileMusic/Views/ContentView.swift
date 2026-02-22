import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                ChannelListView()
                    .tabItem {
                        Label("Channels", systemImage: "radio")
                    }

                FavoritesView()
                    .tabItem {
                        Label("Favorites", systemImage: "star.fill")
                    }

                ProviderListView()
                    .tabItem {
                        Label("Providers", systemImage: "server.rack")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }

            if audioPlayer.currentChannel != nil {
                MiniPlayerView()
                    .padding(.bottom, 49) // TabBar height offset
            }
        }
        .glassContainer()
    }
}
