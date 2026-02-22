import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var searchText = ""

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
        }
    }

    private var channelList: some View {
        List {
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.channels) { channel in
                        ChannelRowView(channel: channel) {
                            audioPlayer.channels = providerManager.channels
                            audioPlayer.play(channel: channel)
                        } onToggleFavorite: {
                            Task { await providerManager.toggleFavorite(channel) }
                        }
                    }
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
