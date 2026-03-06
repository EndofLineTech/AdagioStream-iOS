import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var sxmService: SXMMetadataService
    @State private var selectedTab = 0
    @State private var hasAttemptedStartupStream = false

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

                SavedSongsView()
                    .tabItem {
                        Label("Loved", systemImage: "heart.fill")
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
        .task { await performStartupStream() }
        .onChange(of: selectedTab) { newTab in
            // Only poll SXM feed when channel list or favorites are visible
            sxmService.setFeedPollingEnabled(newTab == 0 || newTab == 1)
        }
        .onAppear {
            sxmService.setFeedPollingEnabled(selectedTab == 0 || selectedTab == 1)
        }
    }

    private func performStartupStream() async {
        guard !hasAttemptedStartupStream else { return }
        hasAttemptedStartupStream = true

        await settingsViewModel.loadSettings()
        let startupID = settingsViewModel.settings.startupStreamID
            ?? UserDefaults.standard.string(forKey: "lastPlayedChannelID")
        guard let startupID else { return }
        guard audioPlayer.currentChannel == nil else { return }

        // If channels are already loaded, play immediately
        let visible = providerManager.visibleChannels
        if let channel = visible.first(where: { $0.id == startupID }) {
            audioPlayer.channels = visible
            audioPlayer.play(channel: channel)
            return
        }

        // Wait for channels to load
        for await _ in providerManager.$channels.values {
            let vis = providerManager.visibleChannels
            guard !vis.isEmpty else { continue }
            if let channel = vis.first(where: { $0.id == startupID }) {
                audioPlayer.channels = vis
                audioPlayer.play(channel: channel)
            }
            return
        }
    }
}
