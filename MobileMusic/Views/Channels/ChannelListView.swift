import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var hasInitializedGroups = false

    var body: some View {
        NavigationStack {
            Group {
                if providerManager.isLoading {
                    ProgressView("Loading channels...")
                } else if providerManager.channels.isEmpty {
                    EmptyStateView(
                        title: "No Channels",
                        systemImage: "radio",
                        description: "Add a provider to load channels."
                    )
                } else {
                    channelList
                }
            }
            .navigationTitle("Channels")
            .searchable(text: $searchText, prompt: "Search channels")
            .refreshable {
                await providerManager.loadChannels()
            }
            .task {
                if providerManager.channels.isEmpty && !providerManager.providers.isEmpty {
                    await providerManager.loadChannels()
                }
            }
            .onChange(of: providerManager.channels) { _ in
                if !hasInitializedGroups && !providerManager.channels.isEmpty {
                    collapsedGroups = Set(providerManager.channels.map(\.group))
                    hasInitializedGroups = true
                }
            }
        }
    }

    private var channelList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    if !collapsedGroups.contains(group.name) {
                        ForEach(group.channels) { channel in
                            ChannelRowView(channel: channel) {
                                audioPlayer.channels = providerManager.channels
                                audioPlayer.play(channel: channel)
                            } onToggleFavorite: {
                                Task { await providerManager.toggleFavorite(channel) }
                            }
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            if collapsedGroups.contains(group.name) {
                                collapsedGroups.remove(group.name)
                            } else {
                                collapsedGroups.insert(group.name)
                            }
                        }
                    } label: {
                        HStack {
                            Text(group.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .textCase(.none)
                            Spacer()
                            Text("\(group.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: collapsedGroups.contains(group.name) ? "chevron.right" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var groups: [ChannelGroup] {
        let channels = filteredChannels
        let grouped = Dictionary(grouping: channels, by: \.group)
        return grouped.map { ChannelGroup(name: $0.key, channels: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private var filteredChannels: [Channel] {
        if searchText.isEmpty {
            return providerManager.channels
        }
        return providerManager.channels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }
}
