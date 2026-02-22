import SwiftUI

struct ProviderListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @State private var showAddProvider = false

    var body: some View {
        NavigationStack {
            List {
                if providerManager.providers.isEmpty {
                    EmptyStateView(
                        title: "No Providers",
                        systemImage: "server.rack",
                        description: "Add an IPTV provider to get started."
                    )
                } else {
                    ForEach(providerManager.providers) { provider in
                        ProviderRow(provider: provider)
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                await providerManager.deleteProvider(providerManager.providers[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Providers")
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
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.name)
                .font(.headline)
            Text(providerTypeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var providerTypeLabel: String {
        switch provider.type {
        case .m3u: return "M3U Playlist"
        case .xtreamCodes: return "Xtream Codes"
        }
    }
}
