// NavidromeLibraryViewModel+Stars.swift
// Star/rating actions domain (65x.2, beads_mobilemusic-01a). This is the one
// genuinely cross-domain slice: toggling a star or setting a rating has to
// reach into whichever entity (album track, playlist track, the selected
// album, or the selected artist) currently owns the given id. Those
// properties (`selectedAlbumStarState`, `albumTrackStarStates`,
// `selectedArtistStarState`, `playlistTrackStarStates`, `starError`) stay on
// the main type — this file carries the toggle/rate/clear logic only.

import Foundation

extension NavidromeLibraryViewModel {

    public func clearStarError() { starError = nil }

    /// Toggles the star state for any Navidrome entity (track, album, or artist).
    ///
    /// Optimistically updates the local state dictionary before the network call,
    /// then reverts on failure.
    public func toggleStar(id: String) async {
        // Determine current state and the dictionary to update.
        if albumTrackStarStates[id] != nil {
            let currentlyStarred = albumTrackStarStates[id]?.starred ?? false
            albumTrackStarStates[id]?.starred = !currentlyStarred
            do {
                if currentlyStarred {
                    try await api.unstar(id: id)
                } else {
                    try await api.star(id: id)
                }
            } catch let apiErr as NavidromeAPI.APIError {
                albumTrackStarStates[id]?.starred = currentlyStarred // revert
                starError = apiErr.errorDescription ?? "Failed to update star."
            } catch {
                albumTrackStarStates[id]?.starred = currentlyStarred
                starError = error.localizedDescription
            }
        } else if playlistTrackStarStates[id] != nil {
            let currentlyStarred = playlistTrackStarStates[id]?.starred ?? false
            playlistTrackStarStates[id]?.starred = !currentlyStarred
            do {
                if currentlyStarred {
                    try await api.unstar(id: id)
                } else {
                    try await api.star(id: id)
                }
            } catch let apiErr as NavidromeAPI.APIError {
                playlistTrackStarStates[id]?.starred = currentlyStarred
                starError = apiErr.errorDescription ?? "Failed to update star."
            } catch {
                playlistTrackStarStates[id]?.starred = currentlyStarred
                starError = error.localizedDescription
            }
        } else if id == selectedAlbum?.id {
            let currentlyStarred = selectedAlbumStarState?.starred ?? false
            selectedAlbumStarState?.starred = !currentlyStarred
            do {
                if currentlyStarred {
                    try await api.unstar(id: id)
                } else {
                    try await api.star(id: id)
                }
            } catch let apiErr as NavidromeAPI.APIError {
                selectedAlbumStarState?.starred = currentlyStarred
                starError = apiErr.errorDescription ?? "Failed to update star."
            } catch {
                selectedAlbumStarState?.starred = currentlyStarred
                starError = error.localizedDescription
            }
        } else if id == selectedArtist?.id {
            let currentlyStarred = selectedArtistStarState?.starred ?? false
            selectedArtistStarState?.starred = !currentlyStarred
            do {
                if currentlyStarred {
                    try await api.unstar(id: id)
                } else {
                    try await api.star(id: id)
                }
            } catch let apiErr as NavidromeAPI.APIError {
                selectedArtistStarState?.starred = currentlyStarred
                starError = apiErr.errorDescription ?? "Failed to update star."
            } catch {
                selectedArtistStarState?.starred = currentlyStarred
                starError = error.localizedDescription
            }
        }
    }

    /// Sets a 0–5 rating for a track or album.  0 clears the rating.
    ///
    /// Updates the local star-state dictionary optimistically, then reverts on failure.
    public func setRating(id: String, rating: Int) async {
        let previousRating: Int?
        if albumTrackStarStates[id] != nil {
            previousRating = albumTrackStarStates[id]?.userRating
            albumTrackStarStates[id]?.userRating = rating == 0 ? nil : rating
        } else if id == selectedAlbum?.id {
            previousRating = selectedAlbumStarState?.userRating
            selectedAlbumStarState?.userRating = rating == 0 ? nil : rating
        } else {
            return
        }
        do {
            try await api.setRating(id: id, rating: rating)
        } catch let apiErr as NavidromeAPI.APIError {
            // Revert
            if albumTrackStarStates[id] != nil {
                albumTrackStarStates[id]?.userRating = previousRating
            } else {
                selectedAlbumStarState?.userRating = previousRating
            }
            starError = apiErr.errorDescription ?? "Failed to set rating."
        } catch {
            if albumTrackStarStates[id] != nil {
                albumTrackStarStates[id]?.userRating = previousRating
            } else {
                selectedAlbumStarState?.userRating = previousRating
            }
            starError = error.localizedDescription
        }
    }
}
