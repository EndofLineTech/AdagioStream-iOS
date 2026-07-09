import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var providerManager: ProviderManager

    var body: some View {
        if providerManager.providers.isEmpty {
            NoProvidersView()
        } else {
            TabView {
                ChannelsTabView()
                    .tabItem { Label("Channels", systemImage: "radio") }

                // ciu.2: audiobooks tab, only when an ABS provider is configured.
                if providerManager.audiobookshelfAPI != nil {
                    AudiobooksTabView()
                        .tabItem { Label("Audiobooks", systemImage: "books.vertical") }
                }

                NowPlayingTabView()
                    .tabItem { Label("Now Playing", systemImage: "play.circle") }

                SettingsTabView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
    }
}
