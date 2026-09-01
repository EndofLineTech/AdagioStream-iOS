import SwiftUI

struct SiriusXMGroupSelectionTVView: View {
    @EnvironmentObject private var providerManager: ProviderManager
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @State private var isSavingSelection = false

    private var state: SiriusXMGroupSelectionState {
        SiriusXMGroupSelectionState(
            inventory: providerManager.availableRawChannelGroupCounts,
            selectedNames: settingsViewModel.settings.selectedSXMGroupNames,
            inventoryIsComplete: providerManager.hasLoadedCompleteRawChannelGroupInventory
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
                statusContent
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
                Text("This selection is saved on this Apple TV and takes effect immediately. It only controls SiriusXM now-playing matching, not which channels or groups are visible.")
            }
        }
        .navigationTitle(SiriusXMGroupSelectionState.navigationTitle)
        .alert("Couldn't Save Selection", isPresented: settingsErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(settingsViewModel.settingsError ?? "The selection could not be saved.")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if providerManager.isLoading
            || !providerManager.didHydrateProviders
            || (!providerManager.hasLoadedCompleteRawChannelGroupInventory
                && providerManager.channelLoadError == nil) {
            HStack(spacing: 16) {
                ProgressView()
                Text("Loading groups...")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let error = providerManager.channelLoadError {
            VStack(alignment: .leading, spacing: 16) {
                Label("Couldn't Load Groups", systemImage: "exclamationmark.triangle")
                    .font(.title3)
                Text(error)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await providerManager.loadChannels() }
                }
            }
            .padding(.vertical, 12)
        } else if providerManager.providers.isEmpty {
            Label("No Accounts", systemImage: "server.rack")
                .accessibilityHint("A provider account is required to load channel groups")
        } else {
            Label("No channel groups were found", systemImage: "rectangle.3.group")
        }
    }

    private func selectionRow(_ row: SiriusXMGroupSelectionState.Row) -> some View {
        Button {
            guard !isSavingSelection,
                  !settingsViewModel.isSXMSelectionPersistenceInFlight else { return }
            isSavingSelection = true
            let candidate = state.selection(toggling: row.name)
            Task {
                await settingsViewModel.updateSXMGroupSelection(candidate)
                isSavingSelection = false
            }
        } label: {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(.title3)
                    if let channelCount = row.channelCount {
                        Text("\(channelCount) \(channelCount == 1 ? "channel" : "channels")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unavailable")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 20)
                Label(
                    row.selectionLabel,
                    systemImage: row.isSelected ? "checkmark.circle.fill" : "circle"
                )
                .font(.callout.weight(.semibold))
            }
            .padding(.vertical, 8)
        }
        .disabled(isSavingSelection || settingsViewModel.isSXMSelectionPersistenceInFlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityValue(row.selectionLabel)
        .accessibilityHint(row.isSelected ? "Press to deselect" : "Press to select")
    }

    private func accessibilityLabel(for row: SiriusXMGroupSelectionState.Row) -> String {
        if let channelCount = row.channelCount {
            return "\(row.name), \(channelCount) \(channelCount == 1 ? "channel" : "channels")"
        }
        return "\(row.name), unavailable"
    }

    private var settingsErrorIsPresented: Binding<Bool> {
        Binding(
            get: { settingsViewModel.settingsError != nil },
            set: { if !$0 { settingsViewModel.settingsError = nil } }
        )
    }
}
