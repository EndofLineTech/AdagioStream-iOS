import Combine
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case channels
    case favorites
    case loved
    case playlists
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .channels: return "Channels"
        case .favorites: return "Favorites"
        case .loved: return "Loved"
        case .playlists: return "My M3Us"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .channels: return "radio"
        case .favorites: return "star.fill"
        case .loved: return "heart.fill"
        case .playlists: return "music.note.list"
        case .settings: return "gear"
        }
    }

    var isChannelView: Bool {
        self == .channels || self == .favorites
    }
}

struct ContentView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var sxmService: SXMMetadataService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab = 0
    @State private var selectedSidebarItem: SidebarItem? = .channels
    @State private var hasAttemptedStartupStream = false
    @State private var splashOpacity: Double = 1
    @State private var sharedURLEntry: SharedURLEntry?

    var body: some View {
        ZStack {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
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
        .focusable()
        .onKeyPress(characters: .init(charactersIn: " ")) { _ in
            audioPlayer.togglePlayPause()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            audioPlayer.playNext()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            audioPlayer.playPrevious()
            return .handled
        }
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedSidebarItem) { item in
                Label(item.label, systemImage: item.icon)
                    .tag(item)
            }
            .navigationTitle("Adagio Stream")
            .listStyle(.sidebar)
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch selectedSidebarItem {
                    case .channels:
                        ChannelListView()
                    case .favorites:
                        FavoritesView()
                    case .loved:
                        SavedSongsView()
                    case .playlists:
                        CustomPlaylistListView()
                    case .settings:
                        SettingsView()
                    case nil:
                        ContentUnavailableView("Select an Item",
                            systemImage: "sidebar.left",
                            description: Text("Choose a section from the sidebar."))
                    }
                }
                .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)

                if audioPlayer.currentChannel != nil {
                    MiniPlayerView()
                }
            }
        }
        .onChange(of: selectedSidebarItem) { _, newValue in
            let channelsVisible = newValue?.isChannelView ?? false
            sxmService.setFeedPollingEnabled(channelsVisible)
            ESPNScoreService.shared.setPollingEnabled(channelsVisible)
        }
        .onAppear {
            let channelsVisible = selectedSidebarItem?.isChannelView ?? false
            sxmService.setFeedPollingEnabled(channelsVisible)
            ESPNScoreService.shared.setPollingEnabled(channelsVisible)
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneLayout: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                ChannelListView()
                    .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                    .tabItem {
                        Label("Channels", systemImage: "radio")
                    }
                    .tag(0)

                FavoritesView()
                    .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                    .tabItem {
                        Label("Favorites", systemImage: "star.fill")
                    }
                    .tag(1)

                SavedSongsView()
                    .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                    .tabItem {
                        Label("Loved", systemImage: "heart.fill")
                    }
                    .tag(2)

                CustomPlaylistListView()
                    .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                    .tabItem {
                        Label("My M3Us", systemImage: "music.note.list")
                    }
                    .tag(3)

                SettingsView()
                    .contentMargins(.bottom, miniPlayerBottomInset, for: .scrollContent)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(4)
            }

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
