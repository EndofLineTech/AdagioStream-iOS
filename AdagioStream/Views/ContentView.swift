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

                if audioPlayer.hasActivePlayback {
                    MiniPlayerView()
                        .padding(.bottom, Self.tabBarContentHeight)
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
        .task { await dismissSplashWhenReady() }
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
                routeToTabForOnboardedProviders()
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
            Text("Music is now Library. Favorites moved into the Live tab, and Library is now just your Saved songs. Playlists is now Custom M3Us.")
        }
    }

    // MARK: - Tab Content
    // Tab order: Live (0) · Library (1) · Saved (2) · Custom M3Us (3) · Settings (4)

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
                .tabItem { Label("Saved", systemImage: "heart.fill") }
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

    /// Standard compact-height iOS tab bar content height (Apple HIG), used to
    /// float the MiniPlayer above the tab bar. SwiftUI does not expose the
    /// real, Dynamic-Type-aware tab bar height here, so this is a named
    /// approximation rather than a hardcoded magic number (beads_mobilemusic-3h6.13).
    // ponytail: fixed approximation, not measured. Ceiling: drifts under very
    // large Dynamic Type sizes that grow tab bar item text/icons, or if Apple
    // changes the standard tab bar height. Upgrade path: read the actual
    // TabView's bar height via a UIKit-bridged background geometry reader if
    // this ever visibly mismatches.
    private static let tabBarContentHeight: CGFloat = 49

    /// Extra bottom margin so scroll content clears both the tab bar and the
    /// floating MiniPlayer above it. Approximates the MiniPlayer's own
    /// (intrinsically-sized, not fixed-height) rendered height plus the tab
    /// bar — see `tabBarContentHeight` for the same SwiftUI-measurement
    /// limitation.
    // ponytail: same measurement ceiling as tabBarContentHeight — this is the
    // tab bar height plus a small margin for the MiniPlayer's own content,
    // not a real measurement of MiniPlayerView's rendered size.
    private static let miniPlayerClearanceHeight: CGFloat = tabBarContentHeight + 11

    private var miniPlayerBottomInset: CGFloat {
        audioPlayer.hasActivePlayback ? Self.miniPlayerClearanceHeight : 0
    }

    /// After first-run setup, land on the tab matching what the user actually
    /// added — a user who only set up Navidrome/Audiobookshelf shouldn't see
    /// an empty Live tab (beads_mobilemusic-3h6.3). Defaults to Live (current
    /// behavior) whenever a channel source exists or nothing was added.
    private func routeToTabForOnboardedProviders() {
        let hasChannelSource = providerManager.providers.contains { provider in
            switch provider.type {
            case .m3u, .xtreamCodes: return true
            case .subsonic, .audiobookshelf: return false
            }
        }
        if !hasChannelSource && !providerManager.providers.isEmpty {
            selectedTab = Tab.music
        }
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

    /// Cross-fades the splash out as soon as first content is ready, capped at
    /// 2.5s so a slow/unreachable provider never strands the user on the splash
    /// (beads_mobilemusic-3h6.12). "Ready" = settings loaded and the initial
    /// provider/channel load (if any) has settled.
    private func dismissSplashWhenReady() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            group.addTask { @MainActor in
                await settingsViewModel.loadSettings()
                // ProviderManager kicks off its initial load from its own
                // init() Task, which may not have started yet when we
                // subscribe here — give it a beat to flip `isLoading` true
                // before treating an already-`false` read as "done".
                try? await Task.sleep(nanoseconds: 100_000_000)
                for await isLoading in providerManager.$isLoading.values {
                    if !isLoading { break }
                }
            }
            await group.next()
            group.cancelAll()
        }

        withAnimation(.easeOut(duration: 0.8)) {
            splashOpacity = 0
        }
        if !settingsViewModel.settings.hasCompletedSetup {
            showingSetup = true
        } else if !settingsViewModel.settings.hasSeenTabReorgTip {
            showingTabReorgTip = true
        }
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
