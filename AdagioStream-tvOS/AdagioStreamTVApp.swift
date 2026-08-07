import SwiftUI

@main
struct AdagioStreamTVApp: App {
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @StateObject private var providerManager = ProviderManager.shared
    @StateObject private var settingsViewModel = SettingsViewModel(audioPlayer: AudioPlayerService.shared)

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(audioPlayer)
                .environmentObject(providerManager)
                .environmentObject(settingsViewModel)
        }
    }
}
