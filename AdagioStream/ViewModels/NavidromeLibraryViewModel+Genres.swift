// NavidromeLibraryViewModel+Genres.swift
// Genre list domain (0xy.4, beads_mobilemusic-01a). Properties (`genres`,
// `genresState`) stay on the main type — this file carries load logic only.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: genre list (0xy.4)

    /// Fetches all genres via getGenres.
    public func loadGenres() async {
        guard genresState != .loading else { return }
        genres = []
        genresState = .loading
        do {
            let loaded = try await api.getGenres()
            genres = loaded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            genresState = loaded.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            genresState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            genresState = .error(error.localizedDescription)
        }
    }
}
