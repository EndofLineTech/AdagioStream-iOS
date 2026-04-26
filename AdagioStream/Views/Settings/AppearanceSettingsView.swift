import AdagioStreamCore
import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var newPrefix = ""

    var body: some View {
        Form {
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
            } header: {
                Text("Theme")
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
            Section {
                Picker("Channel Sorting", selection: channelSortBinding) {
                    ForEach(ChannelSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Channel Sorting")
            } footer: {
                Text("Controls the order channels appear within each group.")
            }

            Section {
                Picker("Group Sorting", selection: groupSortBinding) {
                    ForEach(ChannelSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Group Sorting")
            } footer: {
                Text("Controls the order groups appear in your channel list. Favorite groups always appear first.")
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
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
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

    private var artworkDisplayBinding: Binding<ArtworkDisplayMode> {
        Binding(
            get: { viewModel.settings.artworkDisplayMode },
            set: { newValue in
                Task { await viewModel.updateArtworkDisplayMode(newValue) }
            }
        )
    }
}
