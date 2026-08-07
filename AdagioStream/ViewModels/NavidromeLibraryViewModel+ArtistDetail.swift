// NavidromeLibraryViewModel+ArtistDetail.swift
// Artist detail (albums) domain (beads_mobilemusic-01a). Properties
// (`selectedArtist`, `artistAlbums`, `albumsState`, `selectedArtistStarState`)
// stay on the main type — this file carries load/reset logic only.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: albums for an artist

    public func loadAlbums(for artist: Artist) async {
        guard albumsState != .loading else { return }
        selectedArtist = artist
        artistAlbums = []
        selectedArtistStarState = nil
        albumsState = .loading
        do {
            let (_, artistStarState, albums) = try await api.getArtistWithStarState(id: artist.id)
            selectedArtistStarState = artistStarState
            artistAlbums = albums.sorted {
                // Sort by year ascending; ties broken by album title.
                switch ($0.year, $1.year) {
                case let (.some(a), .some(b)) where a != b: return a < b
                default: return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
            albumsState = albums.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            albumsState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            albumsState = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset: artist detail

    public func resetArtistDetail() {
        selectedArtist = nil
        artistAlbums = []
        albumsState = .idle
        selectedArtistStarState = nil
    }
}
