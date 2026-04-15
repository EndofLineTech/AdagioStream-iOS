import SwiftUI

struct ChannelsAccountsSettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var showClearFavoritesAlert = false

    var body: some View {
        Form {
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
            }

            Section {
                Picker("Grouping", selection: groupingModeBinding) {
                    ForEach(ChannelGroupingMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Display")
            } footer: {
                Text("All Groups merges channels from all accounts into shared groups. By Provider keeps each account's groups separate. By Source shows the original group from each account.")
            }

            Section {
                HStack {
                    Text("Channels Loaded")
                    Spacer()
                    Text("\(providerManager.visibleChannels.count)")
                        .foregroundStyle(.secondary)
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
                Button(role: .destructive) {
                    showClearFavoritesAlert = true
                } label: {
                    Label("Clear All Favorites", systemImage: "star.slash")
                }
                .disabled(providerManager.favoriteChannels.isEmpty)
            }
        }
        .navigationTitle("Accounts & Channels")
        .alert("Clear Favorites", isPresented: $showClearFavoritesAlert) {
            Button("Clear", role: .destructive) {
                Task { await providerManager.clearFavorites() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all \(providerManager.favoriteChannels.count) channels from your favorites?")
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groupingModeBinding: Binding<ChannelGroupingMode> {
        Binding(
            get: { viewModel.settings.channelGroupingMode },
            set: { newValue in
                Task { await viewModel.updateChannelGroupingMode(newValue, providerManager: providerManager) }
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
}
