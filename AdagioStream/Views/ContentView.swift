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
    /// Controls visibility of the one-time "We reorganized" banner (0xy.5).
    @State private var showingTabReorgTip = false

    // Tab indices — centralised so the onChange logic stays in sync.
    private enum Tab {
        static let live = 0
        static let music = 1
        static let library = 2
        static let playlists = 3
        static let settings = 4
    }

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                tabContent

                if audioPlayer.nowPlaying != nil {
                    MiniPlayerView()
                        .padding(.bottom, 49)
                }
            }
            .glassContainer()
            .onChange(of: selectedTab) { _, newValue in
                // SXM feed polling is only needed on the Live tab.
                let channelsVisible = newValue == Tab.live
                sxmService.setFeedPollingEnabled(channelsVisible)
                ESPNScoreService.shared.setPollingEnabled(channelsVisible)
            }
            .onAppear {
                let channelsVisible = selectedTab == Tab.live
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
                } else if !settingsViewModel.settings.hasSeenTabReorgTip {
                    showingTabReorgTip = true
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
        .alert("We Reorganized", isPresented: $showingTabReorgTip) {
            Button("Got It") {
                Task { await settingsViewModel.markTabReorgTipSeen() }
            }
        } message: {
            Text("Music is now Library. Favorites moved into the Live tab, and Library is now just your Loved songs. Playlists is now Custom M3Us.")
        }
    }

    // MARK: - Tab Content
    // Tab order: Live (0) · Library (1) · Loved (2) · Custom M3Us (3) · Settings (4)

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            ChannelListView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Live", systemImage: "radio") }
                .tag(Tab.live)
            MusicLibraryView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(Tab.music)
            SavedSongsView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Loved", systemImage: "heart.fill") }
                .tag(Tab.library)
            CustomPlaylistListView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Custom M3Us", systemImage: "list.bullet") }
                .tag(Tab.playlists)
            SettingsView()
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    // MARK: - Helpers

    private var miniPlayerBottomInset: CGFloat {
        audioPlayer.nowPlaying != nil ? 60 : 0
    }

    private func checkForSharedURLs() {
        guard let defaults = UserDefaults(suiteName: Constants.AppGroup.identifier) else { return }
        guard let pending = defaults.array(forKey: Constants.AppGroup.pendingSharedURLsKey) as? [[String: String]],
              let first = pending.first,
              let urlString = first["url"],
              let url = URL(string: urlString) else { return }

        let name = first["name"] ?? url.host ?? url.absoluteString

        // Remove the consumed entry
        var remaining = pending
        remaining.removeFirst()
        if remaining.isEmpty {
            defaults.removeObject(forKey: Constants.AppGroup.pendingSharedURLsKey)
        } else {
            defaults.set(remaining, forKey: Constants.AppGroup.pendingSharedURLsKey)
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
