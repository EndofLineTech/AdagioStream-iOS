import SwiftUI

struct ChannelsAccountsSettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel

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
            } header: {
                Text("Display")
            }

            Section {
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
            } footer: {
                Text("\(providerManager.visibleChannels.count) channels loaded · \(providerManager.favoriteChannels.count) favorites")
            }
        }
        .navigationTitle("Channels & Accounts")
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
