import AdagioStreamCore
import Foundation
import SwiftUI

@MainActor
final class ProviderListViewModel: ObservableObject {
    @Published var showAddProvider = false
    @Published var editingProvider: Provider?

    let providerManager: ProviderManager

    init(providerManager: ProviderManager) {
        self.providerManager = providerManager
    }

    func deleteProvider(_ provider: Provider) async {
        await providerManager.deleteProvider(provider)
    }
}
