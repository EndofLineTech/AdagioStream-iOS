import SwiftUI

struct ProviderListView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @State private var showAddProvider = false
    @State private var providerToDelete: Provider?

    var body: some View {
        NavigationStack {
            Group {
                if providerManager.providers.isEmpty {
                    EmptyStateView(
                        title: "No Accounts",
                        systemImage: "server.rack",
                        description: "Add an account to get started."
                    )
                } else {
                    List {
                        ForEach(providerManager.providers) { provider in
                            ProviderRow(provider: provider)
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
                            .disabled(providerManager.isLoading)
                        }
                    }
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
