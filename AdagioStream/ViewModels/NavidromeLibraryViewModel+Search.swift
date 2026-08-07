// NavidromeLibraryViewModel+Search.swift
// Search domain (1x1.2, beads_mobilemusic-01a). Properties (`searchQuery`,
// `searchResults`, `searchState`, `searchAlbumStarStates`,
// `searchSongStarStates`, `searchTask`, `searchDebounceNanoseconds`) stay on
// the main type — this file carries the debounce/fetch/clear logic only.

import Foundation

extension NavidromeLibraryViewModel {

    /// Called by the view on every keystroke.  Cancels any in-flight search,
    /// waits 300 ms, then fires `search3` if the query is still non-empty.
    /// A blank / whitespace-only query resets to `.idle` immediately.
    public func updateSearch(query: String) {
        searchTask?.cancel()
        searchQuery = query

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            searchState = .idle
            return
        }

        let api = self.api
        searchTask = Task { [weak self] in
            // Debounce: sleep 300 ms.  If the task is cancelled during the
            // sleep, the next keystroke has already won — bail out silently.
            do {
                try await Task.sleep(nanoseconds: NavidromeLibraryViewModel.searchDebounceNanoseconds)
            } catch {
                return // Task was cancelled — new keystroke pending
            }

            guard !Task.isCancelled else { return }

            await MainActor.run { self?.searchState = .loading }

            do {
                let results = try await api.search3WithStarState(
                    query: trimmed,
                    artistCount: NavidromeLibraryViewModel.searchResultCap,
                    albumCount: NavidromeLibraryViewModel.searchResultCap,
                    songCount: NavidromeLibraryViewModel.searchResultCap
                )
                guard !Task.isCancelled else { return }
                let plain = NavidromeAPI.SearchResults(
                    artists: results.artists,
                    albums:  results.albums,
                    songs:   results.songs
                )
                await MainActor.run {
                    self?.searchResults = plain
                    self?.searchAlbumStarStates = results.albumStarStates
                    self?.searchSongStarStates  = results.songStarStates
                    let hasAny = !results.artists.isEmpty || !results.albums.isEmpty || !results.songs.isEmpty
                    self?.searchState = hasAny ? .loaded : .empty
                }
            } catch let apiErr as NavidromeAPI.APIError {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.searchState = .error(apiErr.errorDescription ?? "Unknown error")
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.searchState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Clears all search state — called when the search field is dismissed.
    public func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = .empty
        searchAlbumStarStates = [:]
        searchSongStarStates  = [:]
        searchState = .idle
    }
}
