import SwiftUI

struct ProviderManagementView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @State private var showAddProvider = false
    @State private var providerToEdit: Provider?
    @State private var providerToDelete: Provider?

    var body: some View {
        List {
            ForEach(providerManager.providers) { provider in
                providerRow(provider)
            }
            .onDelete { indexSet in
                if let index = indexSet.first {
                    providerToDelete = providerManager.providers[index]
                }
            }

            Section {
                Button {
                    Task { await providerManager.loadChannels() }
                } label: {
                    HStack {
                        Label("Reload All Channels", systemImage: "arrow.clockwise")
                        Spacer()
                        if providerManager.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(providerManager.isLoading || providerManager.providers.isEmpty)
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddProvider = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderView()
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $providerToEdit) { provider in
            AddProviderView(editing: provider)
                .presentationDetents([.medium, .large])
        }
        .alert("Account Ready", isPresented: .init(
            get: { providerManager.newProviderInfo != nil },
            set: { if !$0 { providerManager.newProviderInfo = nil } }
        )) {
            Button("OK") { providerManager.newProviderInfo = nil }
        } message: {
            if let info = providerManager.newProviderInfo {
                Text("\"\(info.providerName)\" loaded \(info.channelCount) channels in \(info.groupCount) groups. All groups are hidden — enable the ones you want in Settings → Groups.")
            }
        }
        .alert("Delete Account", isPresented: .init(
            get: { providerToDelete != nil },
            set: { if !$0 { providerToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let provider = providerToDelete {
                    Task {
                        await providerManager.deleteProvider(provider)
                        await providerManager.loadChannels()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let provider = providerToDelete {
                Text("Are you sure you want to delete \"\(provider.name)\"? Its channels will be removed.")
            }
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        Toggle(isOn: Binding(
            get: { provider.isEnabled },
            set: { _ in Task { await providerManager.toggleProviderEnabled(provider) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(providerTypeLabel(provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let count = providerManager.channelCountByProvider[provider.id] {
                        Text("\(count) channels")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .toggleStyle(.switch)
        .swipeActions(edge: .leading) {
            Button { providerToEdit = provider } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button { providerToEdit = provider } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) { providerToDelete = provider } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func providerTypeLabel(_ provider: Provider) -> String {
        switch provider.type {
        case .m3u: return "M3U Playlist"
        case .xtreamCodes: return "Xtream Codes"
        }
    }
}
