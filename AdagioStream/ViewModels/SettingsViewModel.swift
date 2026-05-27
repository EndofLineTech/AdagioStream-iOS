import Foundation
import SwiftUI
import UIKit

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
        var migrationNote: String?
        if settings.bufferDuration > 15 {
            settings.bufferDuration = 15
            migrationNote = "clamped from >15s"
        }
        // One-time bump: 2s was the original default and proved too tight for
        // cellular driving (skipping, cutouts).  Users still at exactly 2.0
        // are almost certainly on the old default, never having moved the
        // slider — push them to the new default.
        if settings.bufferDuration == Constants.legacyDefaultBufferDuration {
            settings.bufferDuration = Constants.defaultBufferDuration
            migrationNote = "migrated legacy default \(Int(Constants.legacyDefaultBufferDuration))s -> \(Int(Constants.defaultBufferDuration))s"
        }
        if migrationNote != nil {
            try? await persistence.save(settings, to: Constants.StorageKeys.settings)
        }
        let source = migrationNote ?? "loaded from persisted settings"
        DebugLogger.shared.log("Settings loaded: bufferDuration=\(Int(settings.bufferDuration))s (\(source))", category: .player)
        audioPlayer.updateBufferDuration(settings.bufferDuration)
        audioPlayer.artworkDisplayMode = settings.artworkDisplayMode
        DebugLogger.shared.isEnabled = settings.debugLoggingEnabled
        ESPNScoreService.shared.setLivePollInterval(settings.espnLivePollInterval.interval)
        logSettingsSnapshot()
    }

    /// Dumps a redacted snapshot of all user-facing settings + environment to
    /// the debug log.  Used when triaging logs uploaded by users: gives us
    /// what knobs are set without leaking provider URLs, credentials, or
    /// individually identifying stream IDs.
    private func logSettingsSnapshot() {
        let log = DebugLogger.shared
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let providers = ProviderManager.shared.providers
        let providerSummary: String
        if providers.isEmpty {
            providerSummary = "0 (or still loading)"
        } else {
            var xtreamCount = 0
            var m3uCount = 0
            var enabledCount = 0
            for provider in providers {
                if provider.isEnabled { enabledCount += 1 }
                switch provider.type {
                case .xtreamCodes: xtreamCount += 1
                case .m3u: m3uCount += 1
                }
            }
            providerSummary = "total=\(providers.count), enabled=\(enabledCount), xtreamCodes=\(xtreamCount), m3u=\(m3uCount)"
        }
        let channels = ProviderManager.shared.channels.count
        let snapshot = """
        ===== SETTINGS SNAPSHOT =====
        Build: v\(version) (\(build))
        OS: iOS \(device.systemVersion) on \(deviceModelIdentifier()) (\(device.model))
        Locale: \(Locale.current.identifier)
        --- Playback ---
        bufferDuration: \(Int(settings.bufferDuration))s
        artworkDisplayMode: \(settings.artworkDisplayMode)
        startupStreamID: \(settings.startupStreamID == nil ? "unset" : "set (redacted)")
        --- Display ---
        appearanceMode: \(settings.appearanceMode)
        textSizeMode: \(settings.textSizeMode)
        channelGroupingMode: \(settings.channelGroupingMode)
        channelSortOrder: \(settings.channelSortOrder)
        groupSortOrder: \(settings.groupSortOrder)
        sortPrefixes: \(settings.sortPrefixes)
        --- Services ---
        espnLivePollInterval: \(settings.espnLivePollInterval.label)
        debugLoggingEnabled: \(settings.debugLoggingEnabled)
        hasCompletedSetup: \(settings.hasCompletedSetup)
        --- Data ---
        providers: \(providerSummary)
        channels: \(channels)
        --- Network ---
        path: \(audioPlayer.networkPathSummary)
        ============================
        """
        for line in snapshot.split(separator: "\n", omittingEmptySubsequences: false) {
            log.log(String(line), category: .general)
        }
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "unknown" : identifier
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
