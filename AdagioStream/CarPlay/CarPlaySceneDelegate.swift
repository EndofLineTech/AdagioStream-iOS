import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var templateManager: CarPlayTemplateManager?
    private let log = DebugLogger.shared

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        // SettingsViewModel (the only other path that enables DebugLogger)
        // lives on the iOS scene's WindowGroup and never runs on a
        // CarPlay-only cold launch, so without this the failure case we
        // are trying to capture produces no log file.
        applyDebugLoggingPreference()
        log.log("CarPlay CONNECTED", category: .carplay)
        self.interfaceController = interfaceController
        templateManager = CarPlayTemplateManager(
            interfaceController: interfaceController,
            audioPlayer: AudioPlayerService.shared,
            providerManager: ProviderManager.shared
        )
        templateManager?.configure()
        SXMMetadataService.shared.setFeedPollingEnabled(true)
        ESPNScoreService.shared.setPollingEnabled(true)
        // Recover from interruptions whose ENDED event was never delivered
        // (common when CarPlay disconnects during an active interruption).
        AudioPlayerService.shared.recoverStaleInterruption()
        // Assert ourselves as a now-playing candidate before the user
        // selects a channel.  Without this, after a CarPlay-only cold
        // launch (process spawned by CarPlay scene with no prior iOS
        // window), iOS may not route MPRemoteCommandCenter events to us
        // until something else convinces it we're the now-playing app —
        // causing the "steering wheel did nothing for 4 minutes" symptom
        // reported in bd 651.2.
        AudioPlayerService.shared.prewarmRemoteCommands()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        log.log("CarPlay DISCONNECTED", category: .carplay)
        SXMMetadataService.shared.setFeedPollingEnabled(false)
        ESPNScoreService.shared.setPollingEnabled(false)
        self.interfaceController = nil
        self.templateManager = nil
        AudioPlayerService.shared.stopAndClearInterruption()
    }

    /// Reads `AppSettings.debugLoggingEnabled` directly from disk and
    /// applies it to `DebugLogger.shared`. Bypasses `PersistenceService`'s
    /// actor isolation deliberately: we need this before any `await` so
    /// the very first `CarPlay CONNECTED` log line is captured. Safe
    /// because the actor writes atomically.
    private func applyDebugLoggingPreference() {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent(Constants.StorageKeys.settings)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }
        DebugLogger.shared.isEnabled = settings.debugLoggingEnabled
    }
}
