import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var showClearFavoritesAlert = false
    @State private var showClearLogsAlert = false
    @State private var showShareSheet = false
    @State private var showShareWarning = false
    @State private var logSize = DebugLogger.shared.logFileSize()
    @State private var newPrefix = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $viewModel.settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.settings.appearanceMode) { _, newValue in
                        Task { await viewModel.updateAppearance(newValue) }
                    }
                }

                Section {
                    Picker("Text Size", selection: $viewModel.settings.textSizeMode) {
                        ForEach(TextSizeMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: viewModel.settings.textSizeMode) { _, newValue in
                        Task { await viewModel.updateTextSize(newValue) }
                    }
                    Text("Preview: The quick brown fox")
                        .font(.body)
                } header: {
                    Text("Text Size")
                } footer: {
                    Text("System follows your device's text size setting.")
                }

                Section {
                    Picker("Artwork Display", selection: artworkDisplayBinding) {
                        ForEach(ArtworkDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Artwork")
                } footer: {
                    Text("Choose whether to display track cover art or the channel logo in the player and CarPlay.")
                }

                Section("Playback") {
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
                        Text("Higher values improve stability on slow connections but increase initial load time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Live Score Updates", selection: espnLivePollBinding) {
                        ForEach(ESPNLivePollInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                }

                Section {
                    Picker("Channel", selection: startupStreamBinding) {
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

                Section("Channels") {
                    Picker("Grouping", selection: groupingModeBinding) {
                        ForEach(ChannelGroupingMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("Group Sort", selection: groupSortBinding) {
                        ForEach(ChannelSortOrder.allCases, id: \.self) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    Picker("Channel Sort", selection: channelSortBinding) {
                        ForEach(ChannelSortOrder.allCases, id: \.self) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    HStack {
                        Text("Loaded Channels")
                        Spacer()
                        Text("\(providerManager.visibleChannels.count)")
                            .foregroundStyle(.secondary)
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
                    HStack {
                        Text("Favorites")
                        Spacer()
                        Text("\(providerManager.favoriteChannels.count)")
                            .foregroundStyle(.secondary)
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
                }

                Section {
                    ForEach(viewModel.settings.sortPrefixes, id: \.self) { prefix in
                        Text(prefix)
                    }
                    .onDelete { indexSet in
                        viewModel.settings.sortPrefixes.remove(atOffsets: indexSet)
                        Task { await viewModel.saveSettings() }
                    }
                    HStack {
                        TextField("New prefix...", text: $newPrefix)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Add") {
                            let trimmed = newPrefix.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty,
                                  !viewModel.settings.sortPrefixes.contains(trimmed) else { return }
                            viewModel.settings.sortPrefixes.append(trimmed)
                            newPrefix = ""
                            Task { await viewModel.saveSettings() }
                        }
                        .disabled(newPrefix.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Sort Prefixes")
                } footer: {
                    Text("Channel names starting with these prefixes will be sorted by the text after the prefix (e.g. \"Radio: Jazz\" sorts under J).")
                }

                Section("Data") {
                    Button(role: .destructive) {
                        showClearFavoritesAlert = true
                    } label: {
                        Label("Clear All Favorites", systemImage: "star.slash")
                    }
                    .disabled(providerManager.favoriteChannels.isEmpty)
                }

                Section {
                    Toggle("Enable Debug Logging", isOn: debugLoggingBinding)

                    Button {
                        showShareWarning = true
                    } label: {
                        HStack {
                            Label("Share Logs", systemImage: "square.and.arrow.up")
                            Spacer()
                            Text(logSize)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!FileManager.default.fileExists(atPath: DebugLogger.shared.logFileURL.path))

                    Button(role: .destructive) {
                        showClearLogsAlert = true
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                    .disabled(!FileManager.default.fileExists(atPath: DebugLogger.shared.logFileURL.path))
                } header: {
                    Text("Debug Logs")
                } footer: {
                    Text("When enabled, logs record player, CarPlay, call, and Siri events for troubleshooting. Share them via AirDrop, email, or save to Files.")
                }

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
            .alert("Clear Favorites", isPresented: $showClearFavoritesAlert) {
                Button("Clear", role: .destructive) {
                    Task { await providerManager.clearFavorites() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove all \(providerManager.favoriteChannels.count) channels from your favorites?")
            }
            .alert("Clear Logs", isPresented: $showClearLogsAlert) {
                Button("Clear", role: .destructive) {
                    DebugLogger.shared.clearLogs()
                    logSize = DebugLogger.shared.logFileSize()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Delete all debug log files?")
            }
            .alert("Share Debug Logs", isPresented: $showShareWarning) {
                Button("Share") { showShareSheet = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Log files may contain channel names, server addresses, and connection details. Review the file before sharing publicly.")
            }
            .sheet(isPresented: $showShareSheet) {
                logSize = DebugLogger.shared.logFileSize()
            } content: {
                ShareSheet(activityItems: [DebugLogger.shared.logFileURL])
                    .presentationDetents([.medium, .large])
            }
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

    private var channelSortBinding: Binding<ChannelSortOrder> {
        Binding(
            get: { viewModel.settings.channelSortOrder },
            set: { newValue in
                Task { await viewModel.updateChannelSortOrder(newValue, providerManager: providerManager) }
            }
        )
    }

    private var groupSortBinding: Binding<ChannelSortOrder> {
        Binding(
            get: { viewModel.settings.groupSortOrder },
            set: { newValue in
                Task { await viewModel.updateGroupSortOrder(newValue, providerManager: providerManager) }
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

    private var debugLoggingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.debugLoggingEnabled },
            set: { newValue in
                Task { await viewModel.updateDebugLogging(newValue) }
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
