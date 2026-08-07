import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var sxmService: SXMMetadataService
    @ObservedObject var espnService = ESPNScoreService.shared
    @State private var searchText = ""
    @State private var channelToAdd: Channel?
    @State private var epgChannel: Channel?

    /// Sentinel expand-key for the Favorites section; the leading NUL can't
    /// appear in an M3U group-title, so a real group named "Favorites" can't collide.
    private static let favoritesKey = "\u{0}favorites"

    var body: some View {
        NavigationStack {
            Group {
                if providerManager.isLoading && providerManager.channels.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Loading channels...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else if providerManager.channels.isEmpty && providerManager.providers.isEmpty {
                    ScrollView {
                        EmptyStateView(
                            title: "No Accounts",
                            systemImage: "server.rack",
                            description: "Add an account in Settings → Accounts to get started."
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else if providerManager.channels.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            EmptyStateView(
                                title: "No Channels",
                                systemImage: "radio",
                                description: providerManager.error != nil
                                    ? "Pull down to retry.\n\n\(providerManager.error!)"
                                    : "No channels loaded from your accounts."
                            )
                            Button {
                                Task { await providerManager.loadChannels() }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else if providerManager.sortedVisibleGroups.isEmpty {
                    ScrollView {
                        EmptyStateView(
                            title: "All Groups Hidden",
                            systemImage: "eye.slash",
                            description: "Enable groups in Settings → Groups to see channels here."
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else {
                    channelList
                }
            }
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            withAnimation {
                                providerManager.expandedGroups.formUnion(groups.map(\.name) + [Self.favoritesKey])
                            }
                        } label: {
                            Label("Expand All", systemImage: "chevron.down")
                        }
                        Button {
                            withAnimation {
                                providerManager.expandedGroups.removeAll()
                            }
                        } label: {
                            Label("Collapse All", systemImage: "chevron.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Group options")
                }
            }
            .searchable(text: $searchText, prompt: "Search channels")
            .refreshable {
                await providerManager.loadChannels()
            }
            .task {
                if providerManager.channels.isEmpty && !providerManager.providers.isEmpty {
                    await providerManager.loadChannels()
                }
            }
            .sheet(item: $channelToAdd) { channel in
                AddToPlaylistSheet(channel: channel)
                    .presentationDetents([.medium])
            }
            .sheet(item: $epgChannel) { channel in
                NavigationStack {
                    EPGView(channelID: channel.epgChannelID ?? channel.id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { epgChannel = nil }
                            }
                        }
                }
            }
        }
    }

    private var channelList: some View {
        List {
            if !providerManager.favoriteChannels.isEmpty && searchText.isEmpty {
                Section {
                    if isExpanded(Self.favoritesKey) {
                        ForEach(providerManager.favoriteChannels) { channel in
                            ChannelRowView(
                                channel: channel,
                                nowPlayingTrack: sxmService.feedTracks[channel.id],
                                espnGame: espnService.gamesByChannel[channel.id]
                            ) {
                                audioPlayer.channels = providerManager.favoriteChannels
                                audioPlayer.play(channel: channel)
                            } onToggleFavorite: {
                                Task { await providerManager.toggleFavorite(channel) }
                            } onAddToPlaylist: {
                                channelToAdd = channel
                            } onShowEPG: {
                                epgChannel = channel
                            }
                        }
                    }
                } header: {
                    sectionHeader(
                        title: "Favorites",
                        key: Self.favoritesKey,
                        count: providerManager.favoriteChannels.count,
                        showStar: false
                    )
                }
            }

            if let error = providerManager.error {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                        Spacer()
                        Button("Retry") {
                            Task { await providerManager.loadChannels() }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        // uxd.2: .mini keeps the chip visually compact; the frame
                        // enlarges the tappable region to the 44pt minimum.
                        .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }

            ForEach(groups) { group in
                Section {
                    if isExpanded(group.name) {
                        ForEach(group.channels) { channel in
                            ChannelRowView(
                                channel: channel,
                                nowPlayingTrack: sxmService.feedTracks[channel.id],
                                currentProgram: currentEPG(for: channel),
                                espnGame: espnService.gamesByChannel[channel.id]
                            ) {
                                audioPlayer.channels = group.channels
                                audioPlayer.play(channel: channel)
                            } onToggleFavorite: {
                                Task { await providerManager.toggleFavorite(channel) }
                            } onAddToPlaylist: {
                                channelToAdd = channel
                            } onShowEPG: {
                                epgChannel = channel
                            }
                        }
                    }
                } header: {
                    sectionHeader(
                        title: group.name,
                        key: group.name,
                        count: group.count,
                        showStar: group.isFavorite
                    )
                    .contextMenu {
                        Button {
                            Task { await providerManager.toggleGroupFavorite(group.name) }
                        } label: {
                            Label(
                                group.isFavorite ? "Unfavorite Group" : "Favorite Group",
                                systemImage: group.isFavorite ? "star.slash" : "star"
                            )
                        }
                        Button {
                            Task { await providerManager.toggleGroupEnabled(group.name) }
                        } label: {
                            Label("Hide Group", systemImage: "eye.slash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// While searching, all sections act expanded so matches stay visible.
    private func isExpanded(_ key: String) -> Bool {
        !searchText.isEmpty || providerManager.expandedGroups.contains(key)
    }

    private func sectionHeader(title: String, key: String, count: Int, showStar: Bool) -> some View {
        Button {
            withAnimation {
                if providerManager.expandedGroups.contains(key) {
                    providerManager.expandedGroups.remove(key)
                } else {
                    providerManager.expandedGroups.insert(key)
                }
            }
        } label: {
            HStack {
                if showStar {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .textCase(.none)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: isExpanded(key) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // While searching, all sections render expanded, so toggling would have no visible effect.
        .disabled(!searchText.isEmpty)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded(key) ? "Expanded" : "Collapsed")
        .accessibilityHint(searchText.isEmpty ? "Double tap to \(isExpanded(key) ? "collapse" : "expand")" : "")
        .accessibilityAddTraits(.isHeader)
    }

    private func currentEPG(for channel: Channel) -> EPGEntry? {
        guard let epgID = channel.epgChannelID else { return nil }
        return providerManager.epgData[epgID]?.first(where: \.isCurrentlyAiring)
    }

    private var groups: [ChannelGroup] {
        let base = providerManager.sortedVisibleGroups
        if searchText.isEmpty { return base }
        return base.compactMap { group in
            let filtered = group.channels.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return ChannelGroup(name: group.name, channels: filtered, isFavorite: group.isFavorite)
        }
    }
}
