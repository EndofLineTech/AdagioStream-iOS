import AdagioStreamCore
import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var sxmService: SXMMetadataService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var hasAttemptedStartupStream = false
    @State private var splashOpacity: Double = 1
    @State private var sharedURLEntry: SharedURLEntry?
    @State private var showingSetup = false

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                tabContent

                if audioPlayer.currentChannel != nil {
                    MiniPlayerView()
                        .padding(.bottom, 49)
                }
            }
            .glassContainer()
            .onChange(of: selectedTab) { _, newValue in
                let channelsVisible = newValue == 0 || newValue == 1
                sxmService.setFeedPollingEnabled(channelsVisible)
                ESPNScoreService.shared.setPollingEnabled(channelsVisible)
            }
            .onAppear {
                let channelsVisible = selectedTab == 0 || selectedTab == 1
                sxmService.setFeedPollingEnabled(channelsVisible)
                ESPNScoreService.shared.setPollingEnabled(channelsVisible)
            }

            AdagioStartupView()
                .opacity(splashOpacity)
                .allowsHitTesting(splashOpacity > 0)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.8)) {
                    splashOpacity = 0
                }
                if !settingsViewModel.settings.hasCompletedSetup {
                    showingSetup = true
                }
            }
        }
        .task { await performStartupStream() }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                checkForSharedURLs()
            }
        }
        .sheet(item: $sharedURLEntry) { entry in
            SharedURLSheet(entry: entry)
        }
        .fullScreenCover(isPresented: $showingSetup) {
            WelcomeSetupView {
                showingSetup = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didDeleteAllData)) { _ in
            selectedTab = 0
            showingSetup = true
        }
    }

    // MARK: - Tab Content

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            ChannelListView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Channels", systemImage: "radio") }
                .tag(0)
            FavoritesView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Favorites", systemImage: "star.fill") }
                .tag(1)
            SavedSongsView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Loved", systemImage: "heart.fill") }
                .tag(2)
            CustomPlaylistListView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("My M3Us", systemImage: "music.note.list") }
                .tag(3)
            SettingsView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    // MARK: - Helpers

    private var miniPlayerBottomInset: CGFloat {
        audioPlayer.currentChannel != nil ? 60 : 0
    }

    private func checkForSharedURLs() {
        guard let defaults = UserDefaults(suiteName: "group.com.adagiostream.app") else { return }
        guard let pending = defaults.array(forKey: "pendingSharedURLs") as? [[String: String]],
              let first = pending.first,
              let urlString = first["url"],
              let url = URL(string: urlString) else { return }

        let name = first["name"] ?? url.host ?? url.absoluteString

        // Remove the consumed entry
        var remaining = pending
        remaining.removeFirst()
        if remaining.isEmpty {
            defaults.removeObject(forKey: "pendingSharedURLs")
        } else {
            defaults.set(remaining, forKey: "pendingSharedURLs")
        }

        sharedURLEntry = SharedURLEntry(name: name, url: url)
    }

    private func performStartupStream() async {
        guard !hasAttemptedStartupStream else { return }
        hasAttemptedStartupStream = true

        await settingsViewModel.loadSettings()
        guard let startupID = settingsViewModel.settings.startupStreamID else { return }
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
