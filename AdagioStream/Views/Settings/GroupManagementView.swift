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
                    HStack {
                        Button("Enable All") {
                            Task { await providerManager.setAllGroupsEnabled(true) }
                        }
                        .disabled(providerManager.enabledGroups == nil)
                        Spacer()
                        Button("Disable All") {
                            Task { await providerManager.setAllGroupsEnabled(false) }
                        }
                        .disabled(providerManager.enabledGroups?.isEmpty == true)
                    }
                }
            }

            if !filteredFavoriteGroups.isEmpty {
                Section("Favorite Groups") {
                    ForEach(filteredFavoriteGroups) { group in
                        groupRow(group)
                    }
                    .onMove { source, destination in
                        providerManager.moveGroupFavorite(from: source, to: destination)
                    }
                }
            }

            Section(filteredFavoriteGroups.isEmpty && favoriteGroups.isEmpty ? "Groups" : "Other Groups") {
                ForEach(filteredNonFavoriteGroups) { group in
                    groupRow(group)
                }
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

    private func groupRow(_ group: GroupInfo) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { providerManager.isGroupEnabled(group.name) },
                set: { _ in Task { await providerManager.toggleGroupEnabled(group.name) } }
            )) {
                HStack {
                    Text(group.name)
                    Spacer()
                    Text("\(group.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Button {
                Task { await providerManager.toggleGroupFavorite(group.name) }
            } label: {
                Image(systemName: providerManager.isGroupFavorite(group.name) ? "star.fill" : "star")
                    .foregroundStyle(providerManager.isGroupFavorite(group.name) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
