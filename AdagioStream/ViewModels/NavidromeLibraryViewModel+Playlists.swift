// NavidromeLibraryViewModel+Playlists.swift
// Playlist list/detail/editing domain (msl.2, msl.3, beads_mobilemusic-01a).
// Properties (`playlists`, `playlistsState`, `selectedPlaylist`,
// `playlistTracks`, `playlistTracksState`, `playlistTrackStarStates`,
// `playlistEditError`) stay on the main type — this file carries
// load/reset/edit logic only.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: playlists (msl.2)

    /// Fetches all playlists visible to the authenticated user via getPlaylists.
    public func loadPlaylists() async {
        guard playlistsState != .loading else { return }
        playlists = []
        playlistsState = .loading
        do {
            let loaded = try await api.getPlaylists()
            playlists = loaded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            playlistsState = loaded.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            playlistsState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            playlistsState = .error(error.localizedDescription)
        }
    }

    // MARK: - Load: tracks for a playlist (msl.2)

    /// Fetches the track list for the given playlist via getPlaylist(id:).
    public func loadPlaylist(id: String) async {
        guard playlistTracksState != .loading else { return }
        playlistTracks = []
        playlistTracksState = .loading
        playlistTrackStarStates = [:]
        do {
            let (playlist, tracks, trackStates) = try await api.getPlaylistWithStarState(id: id)
            selectedPlaylist = playlist
            playlistTracks = tracks
            playlistTrackStarStates = trackStates
            playlistTracksState = tracks.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            playlistTracksState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            playlistTracksState = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset helpers: playlist (msl.2)

    public func resetPlaylistDetail() {
        selectedPlaylist = nil
        playlistTracks = []
        playlistTracksState = .idle
        playlistTrackStarStates = [:]
    }

    // MARK: - Playlist editing actions (msl.3)

    /// Clears any surfaced playlist edit error.
    public func clearPlaylistEditError() {
        playlistEditError = nil
    }

    /// Creates a new playlist with the given name and optional initial song IDs,
    /// then refreshes the playlist list.
    ///
    /// On success returns the new `Playlist` (if the server echoes it) or `nil`.
    /// On failure surfaces the error in `playlistEditError`.
    @discardableResult
    public func createPlaylist(name: String, songIds: [String] = []) async -> Playlist? {
        do {
            let created = try await api.createPlaylist(name: name, songIds: songIds)
            // Refresh the list regardless of whether the server echoed the playlist.
            await loadPlaylists()
            return created
        } catch let apiErr as NavidromeAPI.APIError {
            playlistEditError = apiErr.errorDescription ?? "Failed to create playlist."
            return nil
        } catch {
            playlistEditError = error.localizedDescription
            return nil
        }
    }

    /// Deletes a playlist by ID, then refreshes the playlist list.
    public func deletePlaylist(id: String) async {
        do {
            try await api.deletePlaylist(id: id)
            // If we were viewing this playlist, reset the detail.
            if selectedPlaylist?.id == id {
                resetPlaylistDetail()
            }
            await loadPlaylists()
        } catch let apiErr as NavidromeAPI.APIError {
            playlistEditError = apiErr.errorDescription ?? "Failed to delete playlist."
        } catch {
            playlistEditError = error.localizedDescription
        }
    }

    /// Renames an existing playlist, then refreshes the playlist list and
    /// the detail view if the renamed playlist is currently selected.
    public func renamePlaylist(id: String, newName: String) async {
        do {
            try await api.updatePlaylist(playlistId: id, name: newName)
            // Refresh both list and detail.
            await loadPlaylists()
            if selectedPlaylist?.id == id {
                await loadPlaylist(id: id)
            }
        } catch let apiErr as NavidromeAPI.APIError {
            playlistEditError = apiErr.errorDescription ?? "Failed to rename playlist."
        } catch {
            playlistEditError = error.localizedDescription
        }
    }

    /// Removes tracks from a playlist by their **index** positions, then
    /// refreshes the playlist detail.
    ///
    /// Subsonic removal is index-based (0-origin position in the playlist).
    /// The caller must pass the correct indices relative to the current track list.
    public func removeTracksFromPlaylist(playlistId: String, indexes: [Int]) async {
        do {
            try await api.updatePlaylist(playlistId: playlistId, songIndexesToRemove: indexes)
            await loadPlaylist(id: playlistId)
        } catch let apiErr as NavidromeAPI.APIError {
            playlistEditError = apiErr.errorDescription ?? "Failed to remove track."
        } catch {
            playlistEditError = error.localizedDescription
        }
    }

    /// Adds a track to an existing playlist, then refreshes the playlist detail
    /// if that playlist is currently selected.
    public func addTrackToPlaylist(playlistId: String, trackId: String) async {
        do {
            try await api.updatePlaylist(playlistId: playlistId, songIdsToAdd: [trackId])
            if selectedPlaylist?.id == playlistId {
                await loadPlaylist(id: playlistId)
            }
        } catch let apiErr as NavidromeAPI.APIError {
            playlistEditError = apiErr.errorDescription ?? "Failed to add track to playlist."
        } catch {
            playlistEditError = error.localizedDescription
        }
    }
}
