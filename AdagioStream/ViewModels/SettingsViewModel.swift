import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
public final class SettingsViewModel: ObservableObject {
    typealias SettingsSaver = @MainActor (AppSettings, String) async throws -> Void

    @Published public var settings: AppSettings
    @Published public var settingsError: String?
    @Published private(set) var isSXMSelectionPersistenceInFlight = false

    private let persistence = PersistenceService.shared
    private let audioPlayer: AudioPlayerService
    private let providerManager: ProviderManager
    private let settingsFilename: String
    var settingsSaver: SettingsSaver
    private var hasLoadedSettings = false
    private var cancellables = Set<AnyCancellable>()

    public convenience init(audioPlayer: AudioPlayerService) {
        self.init(
            audioPlayer: audioPlayer,
            providerManager: .shared,
            settingsFilename: Constants.StorageKeys.settings,
            automaticallyLoad: true
        )
    }

    init(
        audioPlayer: AudioPlayerService,
        providerManager: ProviderManager,
        settingsFilename: String,
        automaticallyLoad: Bool,
        settingsSaver: SettingsSaver? = nil
    ) {
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
        self.settingsFilename = settingsFilename
        self.settings = AppSettings.default
        self.settingsError = nil
        self.settingsSaver = settingsSaver ?? { settings, filename in
            try await PersistenceService.shared.save(settings, to: filename)
        }
        audioPlayer.settingsViewModel = self
        providerManager.$availableRawChannelGroupNames
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.migrateSXMGroupSelectionIfNeeded()
                }
            }
            .store(in: &cancellables)
        if automaticallyLoad {
            Task { await loadSettings() }
        }
    }

    public func loadSettings() async {
        var loadedSettings: AppSettings = await persistence.loadOrDefault(
            from: settingsFilename,
            default: .default
        )
        var migrationNote: String?
        if loadedSettings.bufferDuration > 15 {
            loadedSettings.bufferDuration = 15
            migrationNote = "clamped from >15s"
        }
        // One-time bump: 2s was the original default and proved too tight for
        // cellular driving (skipping, cutouts).  Users still at exactly 2.0
        // are almost certainly on the old default, never having moved the
        // slider — push them to the new default.
        if loadedSettings.bufferDuration == Constants.legacyDefaultBufferDuration {
            loadedSettings.bufferDuration = Constants.defaultBufferDuration
            migrationNote = "migrated legacy default \(Int(Constants.legacyDefaultBufferDuration))s -> \(Int(Constants.defaultBufferDuration))s"
        }
        if let migrated = LegacySXMGroupSelectionMigration.migrate(
            settings: loadedSettings,
            availableGroupNames: providerManager.availableRawChannelGroupNames,
            inventoryIsComplete: providerManager.hasLoadedCompleteRawChannelGroupInventory
        ) {
            if await persistSXMSettings(migrated) {
                loadedSettings = migrated
                migrationNote = migrationNote ?? "initialized explicit SiriusXM groups from legacy matching"
            }
        } else if migrationNote != nil {
            try? await persistence.save(loadedSettings, to: settingsFilename)
        }
        settings = loadedSettings
        providerManager.setSXMGroupSelection(settings.selectedSXMGroupNames)
        hasLoadedSettings = true
        let source = migrationNote ?? "loaded from persisted settings"
        DebugLogger.shared.log("Settings loaded: bufferDuration=\(Int(settings.bufferDuration))s (\(source))", category: .player)
        audioPlayer.updateBufferDuration(settings.bufferDuration)
        audioPlayer.artworkDisplayMode = settings.artworkDisplayMode
        audioPlayer.applyQueuePreferences(
            repeatMode: settings.repeatMode,
            shuffleEnabled: settings.shuffleEnabled
        )
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
            var subsonicCount = 0
            var absCount = 0
            var enabledCount = 0
            for provider in providers {
                if provider.isEnabled { enabledCount += 1 }
                switch provider.type {
                case .xtreamCodes: xtreamCount += 1
                case .m3u: m3uCount += 1
                case .subsonic: subsonicCount += 1
                case .audiobookshelf: absCount += 1
                }
            }
            providerSummary = "total=\(providers.count), enabled=\(enabledCount), xtreamCodes=\(xtreamCount), m3u=\(m3uCount), subsonic=\(subsonicCount), audiobookshelf=\(absCount)"
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
        carPlayReconnectResume: \(settings.carPlayReconnectResume.rawValue)
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
        try? await persistence.save(settings, to: settingsFilename)
        audioPlayer.updateBufferDuration(settings.bufferDuration)
    }

    func migrateSXMGroupSelectionIfNeeded() async {
        guard hasLoadedSettings,
              let migrated = LegacySXMGroupSelectionMigration.migrate(
                  settings: settings,
                  availableGroupNames: providerManager.availableRawChannelGroupNames,
                  inventoryIsComplete: providerManager.hasLoadedCompleteRawChannelGroupInventory
              ) else { return }

        guard await persistSXMSettings(migrated) else { return }
        settings = migrated
        providerManager.setSXMGroupSelection(migrated.selectedSXMGroupNames)
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

    /// fnv.9: CarPlay-only ordering of Navidrome music vs streaming channel
    /// groups. Does not affect the in-app channel list, so no rebuild is
    /// needed — CarPlayTemplateManager observes providerManager.carPlaySourceOrder.
    public func updateCarPlaySourceOrder(_ order: CarPlaySourceOrder, providerManager: ProviderManager) async {
        settings.carPlaySourceOrder = order
        await saveSettings()
        providerManager.carPlaySourceOrder = order
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

    public func markTabReorgTipSeen() async {
        settings.hasSeenTabReorgTip = true
        await saveSettings()
    }

    public func updateESPNLivePollInterval(_ interval: ESPNLivePollInterval) async {
        settings.espnLivePollInterval = interval
        ESPNScoreService.shared.setLivePollInterval(interval.interval)
        await saveSettings()
    }

    @discardableResult
    public func updateSXMGroupSelection(_ groupNames: Set<String>) async -> Bool {
        var candidate = settings
        candidate.selectedSXMGroupNames = groupNames
        candidate.hasCompletedSXMGroupSelectionMigration = true
        guard await persistSXMSettings(candidate) else { return false }
        settings = candidate
        providerManager.setSXMGroupSelection(groupNames)
        return true
    }

    func resetAfterDeletingAllData() {
        settings = .default
        settingsError = nil
    }

    private func persistSXMSettings(_ candidate: AppSettings) async -> Bool {
        guard !isSXMSelectionPersistenceInFlight else { return false }
        isSXMSelectionPersistenceInFlight = true
        defer { isSXMSelectionPersistenceInFlight = false }

        do {
            try await settingsSaver(candidate, settingsFilename)
            settingsError = nil
            return true
        } catch {
            settingsError = "Failed to save settings: \(error.localizedDescription)"
            return false
        }
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

    /// Toggles offline mode (l31.3).  When on, the Music tab restricts to
    /// downloaded tracks only and suppresses network browse/search calls.
    public func updateOfflineMode(_ enabled: Bool) async {
        settings.offlineMode = enabled
        await saveSettings()
    }

    /// Podcast episode sort order (E3 / c2s.4). Drives both episode list
    /// display order and whole-show auto-play direction — views read
    /// `settings.podcastEpisodeSortOrder.podcastEpisodeOrder` directly, no
    /// AudioPlayerService push needed (unlike bufferDuration/artwork mode).
    public func updatePodcastEpisodeSortOrder(_ order: PodcastEpisodeSortOrder) async {
        settings.podcastEpisodeSortOrder = order
        await saveSettings()
    }

    /// What to auto-play when a podcast episode ends (beads_mobilemusic-5aj.2).
    /// Read directly off `settings.podcastEpisodeEndBehavior` by
    /// `AudioPlayerService` at the moment an episode ends — no push needed.
    public func updatePodcastEpisodeEndBehavior(_ behavior: PodcastEpisodeEndBehavior) async {
        settings.podcastEpisodeEndBehavior = behavior
        await saveSettings()
    }

    /// Auto-delete a downloaded episode once it's marked finished (E4 / 6b5.4).
    /// Default OFF; audiobooks are never affected (checked only on the
    /// episode-ended path — see `AudioPlayerService.audiobookFileEnded`).
    public func updateAutoDeleteEpisodeAfterPlayed(_ enabled: Bool) async {
        settings.autoDeleteEpisodeAfterPlayed = enabled
        await saveSettings()
    }

    /// CarPlay-reconnect resume behavior (beads_mobilemusic-cpr). Off by
    /// default; changing this does NOT touch `handleRouteChange` — the
    /// resume logic lives entirely in `CarPlayTemplateManager`, gated on
    /// this setting, so route-change behavior is unaffected regardless of
    /// value here.
    public func updateCarPlayReconnectResume(_ mode: CarPlayReconnectResume) async {
        settings.carPlayReconnectResume = mode
        await saveSettings()
    }

    /// The "Specific station" CarPlay-resume target. `nil` clears it (e.g.
    /// when the user switches the mode away from `.specific`).
    public func updateCarPlayReconnectSpecificChannel(_ channel: CarPlayResumeChannel?) async {
        settings.carPlayReconnectSpecificChannel = channel
        await saveSettings()
    }
}

/// One-time bridge from the historical runtime group matcher to explicit raw
/// group identities.
enum LegacySXMGroupSelectionMigration {
    private static let legacyGroupPattern = #"(?i)\b(siriusxm|sirius\s*xm|sxm|sirius|xm)\b"#

    static func migrate(
        settings: AppSettings,
        availableGroupNames: Set<String>,
        inventoryIsComplete: Bool
    ) -> AppSettings? {
        guard !settings.hasCompletedSXMGroupSelectionMigration,
              inventoryIsComplete else { return nil }

        var migrated = settings
        migrated.selectedSXMGroupNames = Set(availableGroupNames.filter {
            $0.range(of: legacyGroupPattern, options: .regularExpression) != nil
        })
        migrated.hasCompletedSXMGroupSelectionMigration = true
        return migrated
    }
}
