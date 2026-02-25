import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var showClearFavoritesAlert = false
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
                    .onChange(of: viewModel.settings.appearanceMode) { newValue in
                        Task { await viewModel.updateAppearance(newValue) }
                    }
                }

                Section {
                    Picker("Text Size", selection: $viewModel.settings.textSizeMode) {
                        ForEach(TextSizeMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: viewModel.settings.textSizeMode) { newValue in
                        Task { await viewModel.updateTextSize(newValue) }
                    }
                    Text("Preview: The quick brown fox")
                        .font(.body)
                } header: {
                    Text("Text Size")
                } footer: {
                    Text("System follows your device's text size setting.")
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
                        .onChange(of: viewModel.settings.bufferDuration) { newValue in
                            Task { await viewModel.updateBufferDuration(newValue) }
                        }
                        Text("Higher values improve stability on slow connections but increase initial load time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        }
    }

    private var startupStreamBinding: Binding<String?> {
        Binding(
            get: { viewModel.settings.startupStreamID },
            set: { newValue in
                Task { await viewModel.updateStartupStream(newValue) }
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
