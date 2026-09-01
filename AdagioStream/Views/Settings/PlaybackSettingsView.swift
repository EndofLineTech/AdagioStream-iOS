import SwiftUI

struct PlaybackSettingsView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @AppStorage(SXMMetadataSource.defaultsKey) private var sxmMetadataSourceRaw = SXMMetadataSource.stellartunerlog.rawValue
    @AppStorage(SXMPollInterval.defaultsKey) private var sxmPollIntervalSeconds = SXMPollInterval.defaultSeconds
    @AppStorage(SXMSportsPriority.defaultsKey) private var preferLiveScores = true
    @State private var showingCarPlayResumeChannelPicker = false

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
                Picker("On Reconnect", selection: carPlayReconnectResumeBinding) {
                    ForEach(CarPlayReconnectResume.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if viewModel.settings.carPlayReconnectResume == .specific {
                    Button {
                        showingCarPlayResumeChannelPicker = true
                    } label: {
                        HStack {
                            Text("Station")
                            Spacer()
                            Text(carPlayReconnectSpecificChannelLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("CarPlay")
            } footer: {
                Text("Choose what plays when CarPlay reconnects. Off (default) preserves today's behavior — nothing auto-resumes. \"Last Played\" resumes whatever channel played most recently. \"Specific Station\" always resumes the channel you choose; if it's no longer available, playback simply doesn't start.")
            }

            Section {
                Picker("Live Sports Score Updates", selection: espnLivePollBinding) {
                    ForEach(ESPNLivePollInterval.allCases, id: \.self) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                Toggle("Prefer Live Scores on Sports Channels", isOn: $preferLiveScores)
                    .accessibilityHint("When on, a live game's score and base runners are shown instead of SiriusXM song metadata on channels carrying that game")
                    .onChange(of: preferLiveScores) { _, _ in
                        audioPlayer.refreshNowPlayingInfo()
                    }
                Picker("SiriusXM Metadata Source", selection: $sxmMetadataSourceRaw) {
                    ForEach(SXMMetadataSource.allCases, id: \.rawValue) { source in
                        Text(source.label).tag(source.rawValue)
                    }
                }
                .onChange(of: sxmMetadataSourceRaw) { _, _ in
                    SXMMetadataService.shared.sourceChanged()
                }
                Picker("Now-Playing Refresh", selection: $sxmPollIntervalSeconds) {
                    ForEach(SXMPollInterval.options, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .onChange(of: sxmPollIntervalSeconds) { _, _ in
                    SXMMetadataService.shared.pollIntervalChanged()
                }
                NavigationLink {
                    SiriusXMGroupSelectionView()
                } label: {
                    HStack {
                        Text(SiriusXMGroupSelectionState.settingsRowTitle)
                        Spacer()
                        Text(siriusXMGroupSelectionState.summary)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Live Data")
            } footer: {
                Text("How often to refresh live sports scores from ESPN.com API. Lower values show scores sooner but use more data. \"Prefer Live Scores\" shows a game's score and base runners instead of song metadata on channels carrying that game. SiriusXM song metadata can come from xmplaylist.com or StellarTunerLog; switching takes effect immediately.")
            }

            Section {
                Picker("Episode Order", selection: podcastEpisodeSortOrderBinding) {
                    ForEach(PodcastEpisodeSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                Picker("When an episode ends", selection: podcastEpisodeEndBehaviorBinding) {
                    ForEach(PodcastEpisodeEndBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                Toggle("Delete Episode After Played", isOn: autoDeleteEpisodeAfterPlayedBinding)
                    .accessibilityHint("When on, a downloaded episode is removed from this device once it's marked finished")
            } header: {
                Text("Podcasts")
            } footer: {
                Text("Order episode lists newest or oldest first. \"When an episode ends\" controls whole-show auto-play: stop, jump to the next unplayed episode chronologically, or continue skipping played episodes in the order above. Deleting after played only affects downloaded episodes, never audiobooks.")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCarPlayResumeChannelPicker) {
            CarPlayResumeChannelPickerView()
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

    private var carPlayReconnectResumeBinding: Binding<CarPlayReconnectResume> {
        Binding(
            get: { viewModel.settings.carPlayReconnectResume },
            set: { newValue in
                Task { await viewModel.updateCarPlayReconnectResume(newValue) }
            }
        )
    }

    private var carPlayReconnectSpecificChannelLabel: String {
        guard let ref = viewModel.settings.carPlayReconnectSpecificChannel else { return "Choose…" }
        // sortedVisibleGroups may not have loaded/matched yet (channel-list
        // reload race) — fall back to the stored id so the row never reads
        // as empty while still identifying what's configured.
        let name = providerManager.channels.first(where: {
            $0.id == ref.channelID && $0.providerName == ref.providerName
        })?.name
        return name ?? ref.channelID
    }

    private var espnLivePollBinding: Binding<ESPNLivePollInterval> {
        Binding(
            get: { viewModel.settings.espnLivePollInterval },
            set: { newValue in
                Task { await viewModel.updateESPNLivePollInterval(newValue) }
            }
        )
    }

    private var podcastEpisodeSortOrderBinding: Binding<PodcastEpisodeSortOrder> {
        Binding(
            get: { viewModel.settings.podcastEpisodeSortOrder },
            set: { newValue in
                Task { await viewModel.updatePodcastEpisodeSortOrder(newValue) }
            }
        )
    }

    private var podcastEpisodeEndBehaviorBinding: Binding<PodcastEpisodeEndBehavior> {
        Binding(
            get: { viewModel.settings.podcastEpisodeEndBehavior },
            set: { newValue in
                Task { await viewModel.updatePodcastEpisodeEndBehavior(newValue) }
            }
        )
    }

    private var autoDeleteEpisodeAfterPlayedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.autoDeleteEpisodeAfterPlayed },
            set: { newValue in
                Task { await viewModel.updateAutoDeleteEpisodeAfterPlayed(newValue) }
            }
        )
    }

    private var siriusXMGroupSelectionState: SiriusXMGroupSelectionState {
        SiriusXMGroupSelectionState(
            inventory: providerManager.availableRawChannelGroupCounts,
            selectedNames: viewModel.settings.selectedSXMGroupNames,
            inventoryIsComplete: providerManager.hasLoadedCompleteRawChannelGroupInventory
        )
    }
}

private struct SiriusXMGroupSelectionView: View {
    @EnvironmentObject private var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var searchText = ""
    @State private var isSavingSelection = false

    private var state: SiriusXMGroupSelectionState {
        SiriusXMGroupSelectionState(
            inventory: providerManager.availableRawChannelGroupCounts,
            selectedNames: viewModel.settings.selectedSXMGroupNames,
            inventoryIsComplete: providerManager.hasLoadedCompleteRawChannelGroupInventory,
            searchText: searchText
        )
    }

    var body: some View {
        List {
            Section {
            } footer: {
                Text("Choose groups whose channels should be matched with SiriusXM now-playing data. A match is not guaranteed.")
            }

            if !state.availableRows.isEmpty {
                Section("Groups") {
                    ForEach(state.availableRows) { row in
                        selectionRow(row)
                    }
                }
            }

            if !state.unavailableRows.isEmpty {
                Section {
                    ForEach(state.unavailableRows) { row in
                        selectionRow(row)
                    }
                } header: {
                    Text("Unavailable")
                } footer: {
                    Text("These selected groups are not in the current channel inventory. Deselect them if they are no longer needed.")
                }
            }

            if state.availableRows.isEmpty && state.unavailableRows.isEmpty {
                emptyContent
            }

            if providerManager.channelLoadError != nil && state.hasUnfilteredRows {
                Section {
                    Label("Group inventory may be out of date", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(providerManager.channelLoadError ?? "")
                }
            }

            Section {
            } footer: {
                Text("This selection only controls SiriusXM now-playing matching. It does not change which channels or groups are visible.")
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search groups"
        )
        .navigationTitle(SiriusXMGroupSelectionState.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't Save Selection", isPresented: settingsErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.settingsError ?? "The selection could not be saved.")
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if !searchText.isEmpty && state.hasUnfilteredRows {
            EmptyStateView(
                title: "No Matching Groups",
                systemImage: "magnifyingglass",
                description: "No groups match \"\(searchText)\"."
            )
        } else if providerManager.isLoading
                    || !providerManager.didHydrateProviders
                    || (!providerManager.hasLoadedCompleteRawChannelGroupInventory
                        && providerManager.channelLoadError == nil) {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading groups...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        } else if let error = providerManager.channelLoadError {
            EmptyStateView(
                title: "Couldn't Load Groups",
                systemImage: "exclamationmark.triangle",
                description: error,
                actionLabel: "Retry"
            ) {
                Task { await providerManager.loadChannels() }
            }
        } else if providerManager.providers.isEmpty {
            EmptyStateView(
                title: "No Accounts",
                systemImage: "server.rack",
                description: "Add an account in Settings > Accounts & Channels to load channel groups."
            )
        } else {
            EmptyStateView(
                title: "No Groups",
                systemImage: "rectangle.3.group",
                description: "No channel groups were found in the current account inventory."
            )
        }
    }

    private func selectionRow(_ row: SiriusXMGroupSelectionState.Row) -> some View {
        Button {
            guard !isSavingSelection,
                  !viewModel.isSXMSelectionPersistenceInFlight else { return }
            isSavingSelection = true
            let candidate = state.selection(toggling: row.name)
            Task {
                await viewModel.updateSXMGroupSelection(candidate)
                isSavingSelection = false
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .foregroundStyle(.primary)
                    if let channelCount = row.channelCount {
                        Text("\(channelCount) \(channelCount == 1 ? "channel" : "channels")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(isSavingSelection || viewModel.isSXMSelectionPersistenceInFlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityValue(row.isSelected ? "Selected" : "Unselected")
        .accessibilityHint(row.isSelected ? "Double tap to deselect" : "Double tap to select")
    }

    private var settingsErrorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.settingsError != nil },
            set: { if !$0 { viewModel.settingsError = nil } }
        )
    }

    private func accessibilityLabel(for row: SiriusXMGroupSelectionState.Row) -> String {
        if let channelCount = row.channelCount {
            return "\(row.name), \(channelCount) \(channelCount == 1 ? "channel" : "channels")"
        }
        return "\(row.name), unavailable"
    }
}
