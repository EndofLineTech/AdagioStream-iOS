import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var sxmService: SXMMetadataService
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if providerManager.isLoading && providerManager.channels.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading channels...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if providerManager.channels.isEmpty && providerManager.providers.isEmpty {
                    EmptyStateView(
                        title: "No Accounts",
                        systemImage: "server.rack",
                        description: "Add an account in Settings → Accounts to get started."
                    )
                } else if providerManager.channels.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            title: "No Channels",
                            systemImage: "radio",
                            description: providerManager.error ?? "No channels loaded from your accounts."
                        )
                        Button {
                            Task { await providerManager.loadChannels() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                } else if providerManager.sortedVisibleGroups.isEmpty {
                    EmptyStateView(
                        title: "All Groups Hidden",
                        systemImage: "eye.slash",
                        description: "Enable groups in Settings → Groups to see channels here."
                    )
                } else {
                    channelList
                }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search channels")
            .refreshable {
                await providerManager.loadChannels()
            }
            .task {
                if providerManager.channels.isEmpty && !providerManager.providers.isEmpty {
                    await providerManager.loadChannels()
                }
            }
        }
    }

    private var channelList: some View {
        List {
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
                    }
                }
            }

            ForEach(groups) { group in
                Section {
                    if !providerManager.collapsedGroups.contains(group.name) {
                        ForEach(group.channels) { channel in
                            ChannelRowView(channel: channel, nowPlayingTrack: sxmService.feedTracks[channel.id]) {
                                audioPlayer.channels = group.channels
                                audioPlayer.play(channel: channel)
                            } onToggleFavorite: {
                                Task { await providerManager.toggleFavorite(channel) }
                            }
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            if providerManager.collapsedGroups.contains(group.name) {
                                providerManager.collapsedGroups.remove(group.name)
                            } else {
                                providerManager.collapsedGroups.insert(group.name)
                            }
                        }
                    } label: {
                        HStack {
                            if group.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            Text(group.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .textCase(.none)
                            Spacer()
                            Text("\(group.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: providerManager.collapsedGroups.contains(group.name) ? "chevron.right" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
