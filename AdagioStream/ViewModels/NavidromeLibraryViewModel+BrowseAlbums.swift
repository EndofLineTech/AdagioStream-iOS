// NavidromeLibraryViewModel+BrowseAlbums.swift
// Browse-albums-by-type domain (0xy.4, beads_mobilemusic-01a). Properties
// (`browseAlbumsType`, `browseAlbums`, `browseAlbumsState`,
// `browseAlbumStarStates`, `browseAlbumsHasMore`, `isLoadingMoreBrowseAlbums`)
// stay on the main type — this file carries load/reset logic only.

import Foundation

extension NavidromeLibraryViewModel {

    // MARK: - Load: browse albums by type (0xy.4)

    /// Fetches a page of albums for the given list type via getAlbumList2.
    /// A single page of `albumBrowsePageSize` is fetched (no pagination in 0xy.4).
    public func loadBrowseAlbums(type: NavidromeAPI.AlbumListType) async {
        guard browseAlbumsState != .loading else { return }
        browseAlbumsType = type
        browseAlbums = []
        browseAlbumStarStates = [:]
        browseAlbumsHasMore = false
        browseAlbumsState = .loading
        do {
            let (albums, starStates) = try await api.getAlbumList2WithStarState(
                type: type,
                size: NavidromeLibraryViewModel.albumBrowsePageSize,
                offset: 0
            )
            browseAlbums = albums
            browseAlbumStarStates = starStates
            browseAlbumsHasMore = BrowsePagination.hasMore(
                returnedCount: albums.count,
                requestedPageSize: NavidromeLibraryViewModel.albumBrowsePageSize
            )
            browseAlbumsState = albums.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            browseAlbumsState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            browseAlbumsState = .error(error.localizedDescription)
        }
    }

    /// Fetches the next page of albums (uxc.2 — scroll-driven load-more) and
    /// appends it to `browseAlbums`. No-ops if there's nothing more, a fetch
    /// is already in flight, or the initial page hasn't loaded yet. Best-
    /// effort: a failure just stops further load-more attempts, leaving the
    /// already-loaded page visible.
    public func loadMoreBrowseAlbums() async {
        guard browseAlbumsHasMore, !isLoadingMoreBrowseAlbums, browseAlbumsState == .loaded else { return }
        isLoadingMoreBrowseAlbums = true
        defer { isLoadingMoreBrowseAlbums = false }
        do {
            let (albums, starStates) = try await api.getAlbumList2WithStarState(
                type: browseAlbumsType,
                size: NavidromeLibraryViewModel.albumBrowsePageSize,
                offset: browseAlbums.count
            )
            browseAlbums.append(contentsOf: albums)
            browseAlbumStarStates.merge(starStates) { _, new in new }
            browseAlbumsHasMore = BrowsePagination.hasMore(
                returnedCount: albums.count,
                requestedPageSize: NavidromeLibraryViewModel.albumBrowsePageSize
            )
        } catch {
            browseAlbumsHasMore = false
        }
    }

    // MARK: - Reset: browse albums

    public func resetBrowseAlbums() {
        browseAlbums = []
        browseAlbumStarStates = [:]
        browseAlbumsState = .idle
        browseAlbumsHasMore = false
    }
}
