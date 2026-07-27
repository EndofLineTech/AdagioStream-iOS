import SwiftUI

/// Channel picker for the "Specific station" CarPlay-reconnect resume
/// setting (beads_mobilemusic-cpr). Mirrors `ChannelListView`'s searchable,
/// grouped-by-`ChannelGroup` layout rather than the flat favorites-only
/// `Picker` used by "Startup Channel" — this lets the user pick ANY visible
/// channel, not just a favorited one.
struct CarPlayResumeChannelPickerView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await viewModel.updateCarPlayReconnectSpecificChannel(nil) }
                        dismiss()
                    } label: {
                        HStack {
                            Text("None")
                            Spacer()
                            if viewModel.settings.carPlayReconnectSpecificChannel == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                ForEach(groups) { group in
                    Section(group.name) {
                        ForEach(group.channels) { channel in
                            Button {
                                select(channel)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(channel.name)
                                            .foregroundStyle(.primary)
                                        if let provider = channel.providerName {
                                            Text(provider)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if isSelected(channel) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search channels")
            .navigationTitle("Choose Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func isSelected(_ channel: Channel) -> Bool {
        guard let ref = viewModel.settings.carPlayReconnectSpecificChannel else { return false }
        return ref.channelID == channel.id && ref.providerName == channel.providerName
    }

    private func select(_ channel: Channel) {
        Task {
            await viewModel.updateCarPlayReconnectSpecificChannel(
                CarPlayResumeChannel(channelID: channel.id, providerName: channel.providerName)
            )
        }
        dismiss()
    }

    private var groups: [ChannelGroup] {
        let base = providerManager.sortedVisibleGroups
        if searchText.isEmpty { return base }
        return base.compactMap { group in
            let filtered = group.channels.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return ChannelGroup(name: group.name, channels: filtered, isFavorite: group.isFavorite)
        }
    }
}
