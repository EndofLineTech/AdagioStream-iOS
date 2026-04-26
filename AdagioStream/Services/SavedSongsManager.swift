import AdagioStreamCore
import Foundation

@MainActor
final class SavedSongsManager: ObservableObject {
    static let shared = SavedSongsManager()

    @Published private(set) var songs: [SavedSong] = []

    private init() {
        Task { await loadSongs() }
    }

    func isSaved(trackID: String) -> Bool {
        songs.contains { $0.trackID == trackID }
    }

    /// Toggles save state. Returns `true` if the song is now saved.
    @discardableResult
    func toggleSave(track: SXMTrack, channel: Channel?) -> Bool {
        if let index = songs.firstIndex(where: { $0.trackID == track.id }) {
            songs.remove(at: index)
            persist()
            return false
        } else {
            let saved = SavedSong(track: track, channel: channel)
            songs.insert(saved, at: 0)
            persist()
            return true
        }
    }

    func removeSongs(at offsets: IndexSet) {
        songs.remove(atOffsets: offsets)
        persist()
    }

    func moveSong(from source: IndexSet, to destination: Int) {
        songs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func loadSongs() async {
        songs = await PersistenceService.shared.loadOrDefault(
            from: Constants.StorageKeys.savedSongs,
            default: []
        )
    }

    private func persist() {
        Task {
            try? await PersistenceService.shared.save(songs, to: Constants.StorageKeys.savedSongs)
        }
    }
}
