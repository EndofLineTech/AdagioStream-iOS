import Foundation

@MainActor
final class CustomPlaylistManager: ObservableObject {
    static let shared = CustomPlaylistManager()

    @Published private(set) var playlists: [CustomPlaylist] = []

    private init() {
        Task { await loadPlaylists() }
    }

    // MARK: - Playlist CRUD

    func createPlaylist(name: String) -> CustomPlaylist {
        let playlist = CustomPlaylist(name: name)
        playlists.append(playlist)
        persist()
        return playlist
    }

    func renamePlaylist(_ playlistID: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].name = name
        playlists[index].updatedAt = Date()
        persist()
    }

    func deletePlaylist(_ playlistID: UUID) {
        playlists.removeAll { $0.id == playlistID }
        persist()
    }

    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Group CRUD

    func addGroup(named name: String, to playlistID: UUID) -> CustomPlaylistGroup? {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return nil }
        let group = CustomPlaylistGroup(name: name)
        playlists[index].groups.append(group)
        playlists[index].updatedAt = Date()
        persist()
        return group
    }

    func renameGroup(_ groupID: UUID, to name: String, in playlistID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == playlistID }),
              let gi = playlists[pi].groups.firstIndex(where: { $0.id == groupID }) else { return }
        playlists[pi].groups[gi].name = name
        playlists[pi].updatedAt = Date()
        persist()
    }

    func deleteGroup(_ groupID: UUID, from playlistID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[pi].groups.removeAll { $0.id == groupID }
        playlists[pi].updatedAt = Date()
        persist()
    }

    func moveGroups(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[pi].groups.move(fromOffsets: source, toOffset: destination)
        playlists[pi].updatedAt = Date()
        persist()
    }

    // MARK: - Entry CRUD

    func addEntry(_ entry: CustomPlaylistEntry, to groupID: UUID, in playlistID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == playlistID }),
              let gi = playlists[pi].groups.firstIndex(where: { $0.id == groupID }) else { return }
        playlists[pi].groups[gi].entries.append(entry)
        playlists[pi].updatedAt = Date()
        persist()
    }

    func removeEntry(_ entryID: UUID, from groupID: UUID, in playlistID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == playlistID }),
              let gi = playlists[pi].groups.firstIndex(where: { $0.id == groupID }) else { return }
        playlists[pi].groups[gi].entries.removeAll { $0.id == entryID }
        playlists[pi].updatedAt = Date()
        persist()
    }

    func moveEntries(from source: IndexSet, to destination: Int, in groupID: UUID, in playlistID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == playlistID }),
              let gi = playlists[pi].groups.firstIndex(where: { $0.id == groupID }) else { return }
        playlists[pi].groups[gi].entries.move(fromOffsets: source, toOffset: destination)
        playlists[pi].updatedAt = Date()
        persist()
    }

    // MARK: - Convenience

    func addChannel(_ channel: Channel, to groupID: UUID, in playlistID: UUID) {
        let entry = CustomPlaylistEntry(channel: channel)
        addEntry(entry, to: groupID, in: playlistID)
    }

    // MARK: - Persistence

    private func loadPlaylists() async {
        playlists = await PersistenceService.shared.loadOrDefault(
            from: Constants.StorageKeys.customPlaylists,
            default: []
        )
    }

    private func persist() {
        Task {
            try? await PersistenceService.shared.save(playlists, to: Constants.StorageKeys.customPlaylists)
        }
    }
}
