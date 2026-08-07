import Foundation
import SwiftUI

@MainActor
public final class ProviderListViewModel: ObservableObject {
    @Published public var showAddProvider = false
    @Published public var editingProvider: Provider?

    public let providerManager: ProviderManager

    public init(providerManager: ProviderManager) {
        self.providerManager = providerManager
    }

    public func deleteProvider(_ provider: Provider) async {
        await providerManager.deleteProvider(provider)
    }
}
