import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                ChannelListView()
                    .tabItem {
                        Label("Channels", systemImage: "radio")
                    }
                    .tag(0)

                FavoritesView()
                    .tabItem {
                        Label("Favorites", systemImage: "star.fill")
                    }
                    .tag(1)

                ProviderListView()
                    .tabItem {
                        Label("Providers", systemImage: "server.rack")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(3)
            }

            if audioPlayer.currentChannel != nil {
                MiniPlayerView()
                    .padding(.bottom, 49) // TabBar height offset
            }
        }
        .glassContainer()
    }
}
