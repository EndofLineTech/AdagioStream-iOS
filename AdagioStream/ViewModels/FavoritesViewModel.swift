import Foundation
import SwiftUI

@MainActor
public final class FavoritesViewModel: ObservableObject {
    public let providerManager: ProviderManager

    public init(providerManager: ProviderManager) {
        self.providerManager = providerManager
    }

    public var favorites: [Channel] {
        providerManager.favoriteChannels
    }
}
