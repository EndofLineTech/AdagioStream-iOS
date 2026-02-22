import SwiftUI

@main
struct MobileMusicApp: App {
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @StateObject private var providerManager = ProviderManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
                .environmentObject(providerManager)
        }
    }
}
