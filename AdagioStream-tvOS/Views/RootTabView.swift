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

                NowPlayingTabView()
                    .tabItem { Label("Now Playing", systemImage: "play.circle") }

                SettingsTabView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
    }
}
