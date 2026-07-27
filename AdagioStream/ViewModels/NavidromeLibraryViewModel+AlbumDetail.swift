// NavidromeLibraryViewModel+AlbumDetail.swift
// Album detail (tracks) domain (beads_mobilemusic-01a). Properties
// (`selectedAlbum`, `selectedAlbumArtistName`, `albumTracks`, `tracksState`,
// `selectedAlbumStarState`, `albumTrackStarStates`) stay on the main type —
// this file carries load/reset logic only.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: tracks for an album

    public func loadTracks(for album: Album) async {
        guard tracksState != .loading else { return }
        selectedAlbum = album
        selectedAlbumArtistName = nil
        albumTracks = []
        albumTrackStarStates = [:]
        selectedAlbumStarState = nil
        tracksState = .loading
        do {
            let (returnedAlbum, albumStarState, tracks, trackStates) =
                try await api.getAlbumWithStarState(id: album.id)
            // Use the artist name we already have from the artist list / artist
            // detail load — it's in selectedArtist.name which we loaded one
            // screen back.  No extra network call needed for the common path.
            selectedAlbumArtistName = selectedArtist?.name
            selectedAlbum = returnedAlbum
            selectedAlbumStarState = albumStarState
            albumTrackStarStates = trackStates
            albumTracks = tracks.sorted {
                // Sort by disc then track number.
                if $0.discNumber != $1.discNumber {
                    return $0.discNumber < $1.discNumber
                }
                switch ($0.trackNumber, $1.trackNumber) {
                case let (.some(a), .some(b)): return a < b
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
            tracksState = tracks.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            tracksState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            tracksState = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset: album detail

    public func resetAlbumDetail() {
        selectedAlbum = nil
        selectedAlbumArtistName = nil
        albumTracks = []
        tracksState = .idle
        selectedAlbumStarState = nil
        albumTrackStarStates = [:]
    }
}
