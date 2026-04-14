import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings

    private let persistence = PersistenceService.shared
    private let audioPlayer: AudioPlayerService

    init(audioPlayer: AudioPlayerService) {
        self.audioPlayer = audioPlayer
        self.settings = AppSettings.default
        Task { await loadSettings() }
    }

    func loadSettings() async {
        settings = await persistence.loadOrDefault(from: Constants.StorageKeys.settings, default: .default)
        if settings.bufferDuration > 15 {
            settings.bufferDuration = 15
            try? await persistence.save(settings, to: Constants.StorageKeys.settings)
        }
        audioPlayer.updateBufferDuration(settings.bufferDuration)
        audioPlayer.artworkDisplayMode = settings.artworkDisplayMode
        DebugLogger.shared.isEnabled = settings.debugLoggingEnabled
        ESPNScoreService.shared.setLivePollInterval(settings.espnLivePollInterval.interval)
    }

    func saveSettings() async {
        try? await persistence.save(settings, to: Constants.StorageKeys.settings)
        audioPlayer.updateBufferDuration(settings.bufferDuration)
    }

    func updateBufferDuration(_ duration: TimeInterval) async {
        settings.bufferDuration = duration
        await saveSettings()
    }

    func updateAppearance(_ mode: AppearanceMode) async {
        settings.appearanceMode = mode
        await saveSettings()
    }

    func updateTextSize(_ mode: TextSizeMode) async {
        settings.textSizeMode = mode
        await saveSettings()
    }

    func updateStartupStream(_ channelID: String?) async {
        settings.startupStreamID = channelID
        await saveSettings()
    }

    func updateChannelSortOrder(_ order: ChannelSortOrder, providerManager: ProviderManager) async {
        settings.channelSortOrder = order
        await saveSettings()
        providerManager.channelSortOrder = order
        providerManager.rebuildVisibleGroups()
    }

    func updateGroupSortOrder(_ order: ChannelSortOrder, providerManager: ProviderManager) async {
        settings.groupSortOrder = order
        await saveSettings()
        providerManager.groupSortOrder = order
        providerManager.rebuildVisibleGroups()
    }

    func updateChannelGroupingMode(_ mode: ChannelGroupingMode, providerManager: ProviderManager) async {
        settings.channelGroupingMode = mode
        await saveSettings()
        providerManager.channelGroupingMode = mode
        providerManager.rebuildVisibleGroups()
    }

    func updateArtworkDisplayMode(_ mode: ArtworkDisplayMode) async {
        settings.artworkDisplayMode = mode
        audioPlayer.artworkDisplayMode = mode
        audioPlayer.refreshNowPlayingInfo()
        await saveSettings()
    }

    func completeSetup() async {
        settings.hasCompletedSetup = true
        await saveSettings()
    }

    func updateESPNLivePollInterval(_ interval: ESPNLivePollInterval) async {
        settings.espnLivePollInterval = interval
        ESPNScoreService.shared.setLivePollInterval(interval.interval)
        await saveSettings()
    }

    func updateDebugLogging(_ enabled: Bool) async {
        settings.debugLoggingEnabled = enabled
        DebugLogger.shared.isEnabled = enabled
        await saveSettings()
        if enabled {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            DebugLogger.shared.log("Debug logging ENABLED by user — v\(version) build \(build)", category: .general)
        }
    }
}
