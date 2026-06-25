import SwiftUI
import CarPlay

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Install fatal-event capture as early as possible so a CarPlay-only
        // cold launch that later crashes/wedges still leaves a marker (bd a14).
        CrashReporter.install()
        return true
    }

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

    /// Called by the system when a background URLSession (e.g. the download
    /// manager's `com.adagiostream.downloads` session) finishes delivering
    /// events while the app was suspended.  Store the completion handler on
    /// `DownloadManager.shared` so the session delegate can call it from
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` once all
    /// in-process handling is complete.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == DownloadManager.backgroundSessionIdentifier {
            Task { @MainActor in
                DownloadManager.shared.backgroundCompletionHandler = completionHandler
            }
        } else {
            // Unknown session — call the handler immediately so the system is
            // not left waiting.
            completionHandler()
        }
    }
}

@main
struct AdagioStreamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @StateObject private var providerManager = ProviderManager.shared
    @StateObject private var settingsViewModel = SettingsViewModel(audioPlayer: AudioPlayerService.shared)
    @StateObject private var customPlaylistManager = CustomPlaylistManager.shared
    @StateObject private var downloadManager = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioPlayer)
                .environmentObject(providerManager)
                .environmentObject(settingsViewModel)
                .environmentObject(SXMMetadataService.shared)
                .environmentObject(SavedSongsManager.shared)
                .environmentObject(customPlaylistManager)
                .environmentObject(downloadManager)
                .preferredColorScheme(settingsViewModel.settings.appearanceMode.colorScheme)
                .applyTextSize(settingsViewModel.settings.textSizeMode)
        }
        .defaultSize(width: 1024, height: 768)
        .onChange(of: scenePhase) { _, newValue in
            let isBackground = newValue != .active
            audioPlayer.setBackgroundMode(isBackground)
            SXMMetadataService.shared.setBackgroundMode(isBackground)
        }
    }
}
