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
}
