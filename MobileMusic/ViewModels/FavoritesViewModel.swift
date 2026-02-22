import Foundation
import SwiftUI

@MainActor
final class FavoritesViewModel: ObservableObject {
    let providerManager: ProviderManager

    init(providerManager: ProviderManager) {
        self.providerManager = providerManager
    }

    var favorites: [Channel] {
        providerManager.favoriteChannels
    }
}
