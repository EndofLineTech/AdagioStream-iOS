// NavidromeLibraryViewModel+GenreDetail.swift
// Genre detail (songs by genre) domain (0xy.4, beads_mobilemusic-01a).
// Properties (`selectedGenre`, `genreTracks`, `genreTracksState`,
// `genreTrackStarStates`, `genreTracksHasMore`, `isLoadingMoreGenreTracks`)
// stay on the main type — this file carries load/reset logic only.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: tracks for a genre (0xy.4)

    /// Fetches songs for the given genre via getSongsByGenre.
    /// A single page of `genreSongsPageSize` is fetched (no pagination in 0xy.4).
    public func loadTracks(forGenre genre: Genre) async {
        guard genreTracksState != .loading else { return }
        selectedGenre = genre
        genreTracks = []
        genreTrackStarStates = [:]
        genreTracksHasMore = false
        genreTracksState = .loading
        do {
            let (tracks, starStates) = try await api.getSongsByGenreWithStarState(
                genre: genre.name,
                count: NavidromeLibraryViewModel.genreSongsPageSize,
                offset: 0
            )
            genreTracks = tracks
            genreTrackStarStates = starStates
            genreTracksHasMore = BrowsePagination.hasMore(
                returnedCount: tracks.count,
                requestedPageSize: NavidromeLibraryViewModel.genreSongsPageSize
            )
            genreTracksState = tracks.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            genreTracksState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            genreTracksState = .error(error.localizedDescription)
        }
    }

    /// Fetches the next page of songs for the current genre (uxc.2 —
    /// scroll-driven load-more) and appends it to `genreTracks`. Mirrors
    /// `loadMoreBrowseAlbums`.
    public func loadMoreTracks(forGenre genre: Genre) async {
        guard genreTracksHasMore, !isLoadingMoreGenreTracks, genreTracksState == .loaded else { return }
        isLoadingMoreGenreTracks = true
        defer { isLoadingMoreGenreTracks = false }
        do {
            let (tracks, starStates) = try await api.getSongsByGenreWithStarState(
                genre: genre.name,
                count: NavidromeLibraryViewModel.genreSongsPageSize,
                offset: genreTracks.count
            )
            genreTracks.append(contentsOf: tracks)
            genreTrackStarStates.merge(starStates) { _, new in new }
            genreTracksHasMore = BrowsePagination.hasMore(
                returnedCount: tracks.count,
                requestedPageSize: NavidromeLibraryViewModel.genreSongsPageSize
            )
        } catch {
            genreTracksHasMore = false
        }
    }

    // MARK: - Reset: genre detail

    public func resetGenreDetail() {
        selectedGenre = nil
        genreTracks = []
        genreTrackStarStates = [:]
        genreTracksState = .idle
        genreTracksHasMore = false
    }
}
