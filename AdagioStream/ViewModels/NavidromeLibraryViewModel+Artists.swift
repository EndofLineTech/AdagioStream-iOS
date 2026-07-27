// NavidromeLibraryViewModel+Artists.swift
// Artist list domain (beads_mobilemusic-01a). Properties (`artists`,
// `artistsState`) stay on the main type — Swift extensions cannot hold
// stored properties — this file carries only the load logic.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: artists

    public func loadArtists() async {
        guard artistsState != .loading else { return }
        artistsState = .loading
        do {
            let loaded = try await api.getArtists()
            artists = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            artistsState = loaded.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            artistsState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            artistsState = .error(error.localizedDescription)
        }
    }
}
