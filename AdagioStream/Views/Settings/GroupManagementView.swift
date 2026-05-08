import SwiftUI

struct GroupManagementView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @State private var searchText = ""

    private struct GroupInfo: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
    }

    private var allGroups: [GroupInfo] {
        providerManager.allGroupCounts.map { GroupInfo(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var favoriteGroups: [GroupInfo] {
        providerManager.favoriteGroupOrder.compactMap { name in
            allGroups.first { $0.name == name }
        }
    }

    private var nonFavoriteGroups: [GroupInfo] {
        allGroups.filter { !providerManager.isGroupFavorite($0.name) }
    }

    private var filteredFavoriteGroups: [GroupInfo] {
        guard !searchText.isEmpty else { return favoriteGroups }
        return favoriteGroups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredNonFavoriteGroups: [GroupInfo] {
        guard !searchText.isEmpty else { return nonFavoriteGroups }
        return nonFavoriteGroups.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Section {
                } footer: {
                    Text("Tap \(Image(systemName: "plus.circle.fill")) to add a group to your favorites. Favorite groups appear first in your channel list and CarPlay.")
                }

                Section {
                    Button("Enable All") {
                        Task { await providerManager.setAllGroupsEnabled(true) }
                    }
                    .disabled(providerManager.enabledGroups == nil)
                    Button("Disable All") {
                        Task { await providerManager.setAllGroupsEnabled(false) }
                    }
                    .disabled(providerManager.enabledGroups?.isEmpty == true)
                }
            }

            if !filteredFavoriteGroups.isEmpty {
                Section {
                    ForEach(filteredFavoriteGroups) { group in
                        HStack {
                            groupLabel(group)
                            Spacer()
                            Button {
                                Task { await providerManager.toggleGroupFavorite(group.name) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            Toggle("", isOn: Binding(
                                get: { providerManager.isGroupEnabled(group.name) },
                                set: { _ in Task { await providerManager.toggleGroupEnabled(group.name) } }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .onMove { source, destination in
                        providerManager.moveGroupFavorite(from: source, to: destination)
                    }
                } header: {
                    Text("Favorite Groups")
                } footer: {
                    Text("Favorite groups appear first in your channel list and CarPlay. Tap Edit to reorder them.")
                }
            }

            Section {
                ForEach(filteredNonFavoriteGroups) { group in
                    HStack {
                        groupLabel(group)
                        Spacer()
                        Button {
                            Task { await providerManager.toggleGroupFavorite(group.name) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        Toggle("", isOn: Binding(
                            get: { providerManager.isGroupEnabled(group.name) },
                            set: { _ in Task { await providerManager.toggleGroupEnabled(group.name) } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                Text(favoriteGroups.isEmpty ? "Groups" : "Other Groups")
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search groups")
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !favoriteGroups.isEmpty {
                EditButton()
            }
        }
    }

    private func groupLabel(_ group: GroupInfo) -> some View {
        HStack {
            Text(group.name)
            Text("\(group.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
