// SettingsViewModel depends on AudioPlayerService which is iOS-only per
// Phase 0 G2. Gate the whole file `#if os(iOS)` so the tvOS build sees
// no symbol — tvOS Phase 1 will provide its own settings VM.

#if os(iOS)
import Foundation
import SwiftUI

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var settings: AppSettings

    private let persistence = PersistenceService.shared
    private let audioPlayer: AudioPlayerService

    public init(audioPlayer: AudioPlayerService) {
        self.audioPlayer = audioPlayer
        self.settings = AppSettings.default
        Task { await loadSettings() }
    }

    public func loadSettings() async {
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

    public func saveSettings() async {
        try? await persistence.save(settings, to: Constants.StorageKeys.settings)
        audioPlayer.updateBufferDuration(settings.bufferDuration)
    }

    public func updateBufferDuration(_ duration: TimeInterval) async {
        settings.bufferDuration = duration
        await saveSettings()
    }

    public func updateAppearance(_ mode: AppearanceMode) async {
        settings.appearanceMode = mode
        await saveSettings()
    }

    public func updateTextSize(_ mode: TextSizeMode) async {
        settings.textSizeMode = mode
        await saveSettings()
    }

    public func updateStartupStream(_ channelID: String?) async {
        settings.startupStreamID = channelID
        await saveSettings()
    }

    public func updateChannelSortOrder(_ order: ChannelSortOrder, providerManager: ProviderManager) async {
        settings.channelSortOrder = order
        await saveSettings()
        providerManager.channelSortOrder = order
        providerManager.rebuildVisibleGroups()
    }

    public func updateGroupSortOrder(_ order: ChannelSortOrder, providerManager: ProviderManager) async {
        settings.groupSortOrder = order
        await saveSettings()
        providerManager.groupSortOrder = order
        providerManager.rebuildVisibleGroups()
    }

    public func updateChannelGroupingMode(_ mode: ChannelGroupingMode, providerManager: ProviderManager) async {
        settings.channelGroupingMode = mode
        await saveSettings()
        providerManager.channelGroupingMode = mode
        providerManager.rebuildVisibleGroups()
    }

    public func updateArtworkDisplayMode(_ mode: ArtworkDisplayMode) async {
        settings.artworkDisplayMode = mode
        audioPlayer.artworkDisplayMode = mode
        audioPlayer.refreshNowPlayingInfo()
        await saveSettings()
    }

    public func completeSetup() async {
        settings.hasCompletedSetup = true
        await saveSettings()
    }

    public func updateESPNLivePollInterval(_ interval: ESPNLivePollInterval) async {
        settings.espnLivePollInterval = interval
        ESPNScoreService.shared.setLivePollInterval(interval.interval)
        await saveSettings()
    }

    public func updateDebugLogging(_ enabled: Bool) async {
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

#endif // os(iOS)
