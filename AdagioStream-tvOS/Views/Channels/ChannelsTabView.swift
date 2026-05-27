import SwiftUI

struct ChannelsTabView: View {
    @EnvironmentObject private var providerManager: ProviderManager
    @EnvironmentObject private var audioPlayer: AudioPlayerService

    var body: some View {
        NavigationStack {
            Group {
                if providerManager.isLoading && providerManager.channels.isEmpty {
                    ProgressView("Loading channels…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if providerManager.channels.isEmpty {
                    Text("No channels available.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    channelList
                }
            }
            .navigationTitle("Channels")
        }
    }

    private var channelList: some View {
        List {
            ForEach(groupedChannels, id: \.0) { group, channels in
                Section(group) {
                    ForEach(channels) { channel in
                        ChannelRowTVView(
                            channel: channel,
                            isCurrent: audioPlayer.currentChannel?.id == channel.id,
                            isPlaying: audioPlayer.isPlaying
                        ) {
                            audioPlayer.channels = providerManager.visibleChannels
                            audioPlayer.play(channel: channel)
                        }
                    }
                }
            }
        }
    }

    private var groupedChannels: [(String, [Channel])] {
        let dict = Dictionary(grouping: providerManager.visibleChannels, by: \.group)
        return dict.keys.sorted().map { ($0, dict[$0] ?? []) }
    }
}
