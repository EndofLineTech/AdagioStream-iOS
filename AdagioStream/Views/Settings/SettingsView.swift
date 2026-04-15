import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Appearance
                Section {
                    Picker("Appearance", selection: $viewModel.settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.settings.appearanceMode) { _, newValue in
                        Task { await viewModel.updateAppearance(newValue) }
                    }
                    Picker("Text Size", selection: $viewModel.settings.textSizeMode) {
                        ForEach(TextSizeMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: viewModel.settings.textSizeMode) { _, newValue in
                        Task { await viewModel.updateTextSize(newValue) }
                    }
                    Picker("Artwork Display", selection: artworkDisplayBinding) {
                        ForEach(ArtworkDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Text size \"System\" follows your device's text size setting. Artwork controls what appears in the player and CarPlay.")
                }

                // MARK: - Playback
                Section {
                    Picker("Startup Channel", selection: startupStreamBinding) {
                        Text("None").tag(String?.none)
                        ForEach(providerManager.favoriteChannels) { channel in
                            Text(channel.name).tag(Optional(channel.id))
                        }
                    }
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
                    Picker("Live Score Updates", selection: espnLivePollBinding) {
                        ForEach(ESPNLivePollInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    if providerManager.favoriteChannels.isEmpty {
                        Text("Favorite a channel to set it as your startup channel. Higher buffer values improve stability on slow connections.")
                    } else {
                        Text("Startup channel auto-plays when the app opens. Higher buffer values improve stability on slow connections.")
                    }
                }

                // MARK: - Channels & Accounts
                Section {
                    NavigationLink {
                        ProviderManagementView()
                    } label: {
                        HStack {
                            Text("Accounts")
                            Spacer()
                            Text(providersLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        GroupManagementView()
                    } label: {
                        HStack {
                            Text("Groups")
                            Spacer()
                            Text(groupsLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Grouping", selection: groupingModeBinding) {
                        ForEach(ChannelGroupingMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Button {
                        Task { await providerManager.loadChannels() }
                    } label: {
                        HStack {
                            Label("Reload Channels", systemImage: "arrow.clockwise")
                            Spacer()
                            if providerManager.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(providerManager.isLoading || providerManager.providers.isEmpty)
                } header: {
                    Text("Channels & Accounts")
                } footer: {
                    Text("\(providerManager.visibleChannels.count) channels loaded · \(providerManager.favoriteChannels.count) favorites")
                }

                // MARK: - Advanced
                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Text("Advanced")
                    }
                }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("App")
                        Spacer()
                        Text(Constants.appName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(buildNumber)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Text("Licenses")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var groupingModeBinding: Binding<ChannelGroupingMode> {
        Binding(
            get: { viewModel.settings.channelGroupingMode },
            set: { newValue in
                Task { await viewModel.updateChannelGroupingMode(newValue, providerManager: providerManager) }
            }
        )
    }

    private var startupStreamBinding: Binding<String?> {
        Binding(
            get: { viewModel.settings.startupStreamID },
            set: { newValue in
                Task { await viewModel.updateStartupStream(newValue) }
            }
        )
    }

    private var artworkDisplayBinding: Binding<ArtworkDisplayMode> {
        Binding(
            get: { viewModel.settings.artworkDisplayMode },
            set: { newValue in
                Task { await viewModel.updateArtworkDisplayMode(newValue) }
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

    private var providersLabel: String {
        let total = providerManager.providers.count
        let enabled = providerManager.enabledProviderCount
        if enabled < total {
            return "\(enabled) of \(total)"
        }
        return "\(total)"
    }

    private var groupsLabel: String {
        let total = providerManager.allGroupCounts.count
        if let enabled = providerManager.enabledGroups {
            return "\(enabled.count) of \(total)"
        }
        return "\(total)"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
