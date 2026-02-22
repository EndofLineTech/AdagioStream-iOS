import Foundation
import SwiftUI

@MainActor
final class ChannelListViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var selectedGroup: String?

    let providerManager: ProviderManager

    init(providerManager: ProviderManager) {
        self.providerManager = providerManager
    }

    var filteredChannels: [Channel] {
        var result = providerManager.channels

        if let group = selectedGroup {
            result = result.filter { $0.group == group }
        }

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return result
    }

    var groups: [ChannelGroup] {
        let grouped = Dictionary(grouping: filteredChannels, by: \.group)
        return grouped.map { ChannelGroup(name: $0.key, channels: $0.value) }
            .sorted { $0.name < $1.name }
    }

    var allGroupNames: [String] {
        let names = Set(providerManager.channels.map(\.group))
        return names.sorted()
    }

    func refresh() async {
        await providerManager.loadChannels()
    }
}
