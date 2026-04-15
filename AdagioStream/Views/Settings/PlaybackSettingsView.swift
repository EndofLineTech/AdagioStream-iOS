import SwiftUI

struct PlaybackSettingsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("Startup Channel", selection: startupStreamBinding) {
                    Text("None").tag(String?.none)
                    ForEach(providerManager.favoriteChannels) { channel in
                        Text(channel.name).tag(Optional(channel.id))
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                if providerManager.favoriteChannels.isEmpty {
                    Text("Favorite a channel to set it as your startup channel.")
                } else {
                    Text("Automatically plays this channel when the app opens. Only favorited channels are shown.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Buffer Duration")
                        Spacer()
                        Text("\(Int(viewModel.settings.bufferDuration))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $viewModel.settings.bufferDuration,
                        in: 2...15,
                        step: 1
                    ) {
                        Text("Buffer Duration")
                    }
                    .onChange(of: viewModel.settings.bufferDuration) { _, newValue in
                        Task { await viewModel.updateBufferDuration(newValue) }
                    }
                }
                HStack {
                    Text("Stream Quality")
                    Spacer()
                    if audioPlayer.isPlaying, audioPlayer.streamBitrateKbps > 1 {
                        let formatted = audioPlayer.streamBitrateKbps >= 1000
                            ? String(format: "%.1f Mbps", audioPlayer.streamBitrateKbps / 1000)
                            : "\(Int(audioPlayer.streamBitrateKbps)) kbps"
                        Text(formatted)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not playing")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Stream")
            } footer: {
                Text("Higher buffer values improve stability on slow connections but increase initial load time.")
            }

            Section {
                Picker("Live Score Updates", selection: espnLivePollBinding) {
                    ForEach(ESPNLivePollInterval.allCases, id: \.self) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            } header: {
                Text("Live Data")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var startupStreamBinding: Binding<String?> {
        Binding(
            get: { viewModel.settings.startupStreamID },
            set: { newValue in
                Task { await viewModel.updateStartupStream(newValue) }
            }
        )
    }

    private var espnLivePollBinding: Binding<ESPNLivePollInterval> {
        Binding(
            get: { viewModel.settings.espnLivePollInterval },
            set: { newValue in
                Task { await viewModel.updateESPNLivePollInterval(newValue) }
            }
        )
    }
}
