import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @StateObject private var viewModel: ChannelListViewModel

    init() {
        // Will be properly initialized via environmentObject
        _viewModel = StateObject(wrappedValue: ChannelListViewModel(providerManager: ProviderManager()))
    }

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
            .searchable(text: $viewModel.searchText, prompt: "Search channels")
            .refreshable {
                await viewModel.refresh()
            }
            .onAppear {
                viewModel.providerManager === providerManager ? () : ()
            }
            .task {
                if providerManager.channels.isEmpty {
                    await viewModel.refresh()
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
        if viewModel.searchText.isEmpty {
            return providerManager.channels
        }
        return providerManager.channels.filter {
            $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }
}
