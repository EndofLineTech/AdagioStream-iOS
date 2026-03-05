import SwiftUI
import CarPlay

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: .carTemplateApplication)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        return config
    }
}

@main
struct AdagioStreamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @StateObject private var providerManager = ProviderManager.shared
    @StateObject private var settingsViewModel = SettingsViewModel(audioPlayer: AudioPlayerService.shared)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
                .environmentObject(providerManager)
                .environmentObject(settingsViewModel)
                .environmentObject(SXMMetadataService.shared)
                .environmentObject(SavedSongsManager.shared)
                .preferredColorScheme(settingsViewModel.settings.appearanceMode.colorScheme)
                .applyTextSize(settingsViewModel.settings.textSizeMode)
        }
    }
}
