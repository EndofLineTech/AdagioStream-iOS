// 0xy.3 — Navidrome browse UI: view-model
// 0xy.4 — Extended with album-list-by-type and genre/song-by-genre browsing.
//
// MVVM, @MainActor ObservableObject following the ChannelListViewModel pattern.
// Drives five screens: artist list, artist→albums, album→tracks,
// browse-albums (by type), genres list, genre→tracks.
//
// Loading states: .idle → .loading → .loaded / .error
// Error messages surface NavidromeAPI.APIError.errorDescription directly.
//
// Pagination: album-list-by-type and songs-by-genre fetch a single page of
// size 50.  Pagination is intentionally omitted in this bead; a page-size
// constant is declared here so it is easy to locate and upgrade later.

import Foundation

@MainActor
public final class NavidromeLibraryViewModel: ObservableObject {

    // MARK: - Artist list

    @Published public private(set) var artists: [Artist] = []
    @Published public private(set) var artistsState: LoadState = .idle

    // MARK: - Artist detail (albums)

    @Published public private(set) var selectedArtist: Artist?
    @Published public private(set) var artistAlbums: [Album] = []
    @Published public private(set) var albumsState: LoadState = .idle

    // MARK: - Album detail (tracks)

    @Published public private(set) var selectedAlbum: Album?
    /// Artist display name sourced from the `SubsonicAlbumDTO.artistName` field.
    /// Non-nil when the album detail response includes it; used to show the
    /// human name instead of `artistId` in the track list and now-playing.
    @Published public private(set) var selectedAlbumArtistName: String?
    @Published public private(set) var albumTracks: [Track] = []
    @Published public private(set) var tracksState: LoadState = .idle

    // MARK: - Browse albums by type (0xy.4)

    /// The last album-list type that was successfully fetched (or is loading).
    @Published public private(set) var browseAlbumsType: NavidromeAPI.AlbumListType = .newest
    @Published public private(set) var browseAlbums: [Album] = []
    @Published public private(set) var browseAlbumsState: LoadState = .idle
    /// Per-album star/play-count states for the current browse-albums page.
    /// Keyed by album ID. Populated alongside browseAlbums on each load. (65x.3)
    @Published public private(set) var browseAlbumStarStates: [String: NavidromeAPI.StarState] = [:]
    /// True when the last fetched page was full-size, meaning more albums may
    /// exist server-side (uxc.2 — scroll-driven load-more).
    @Published public private(set) var browseAlbumsHasMore = false
    /// True while a load-more fetch (not the initial page) is in flight.
    @Published public private(set) var isLoadingMoreBrowseAlbums = false

    // MARK: - Genre list (0xy.4)

    @Published public private(set) var genres: [Genre] = []
    @Published public private(set) var genresState: LoadState = .idle

    // MARK: - Genre detail: songs by genre (0xy.4)

    @Published public private(set) var selectedGenre: Genre?
    @Published public private(set) var genreTracks: [Track] = []
    @Published public private(set) var genreTracksState: LoadState = .idle
    /// Per-song star/play-count states for the current genre track page.
    /// Keyed by track ID. Populated alongside genreTracks on each load. (65x.3)
    @Published public private(set) var genreTrackStarStates: [String: NavidromeAPI.StarState] = [:]
    /// True when the last fetched page was full-size, meaning more songs may
    /// exist server-side (uxc.2 — scroll-driven load-more).
    @Published public private(set) var genreTracksHasMore = false
    /// True while a load-more fetch (not the initial page) is in flight.
    @Published public private(set) var isLoadingMoreGenreTracks = false

    // MARK: - Page sizes (single-page, no pagination in 0xy.4)

    /// Maximum albums returned by getAlbumList2 in a single fetch.
    /// Navidrome accepts 1–500; 50 is a reasonable single-page default.
    /// Pagination is deferred to a future bead.
    static let albumBrowsePageSize = 50

    /// Maximum songs returned by getSongsByGenre in a single fetch.
    static let genreSongsPageSize = 50

    /// Cap per category (artists/albums/songs) for `search3` (uxc.2). Kept as
    /// one named constant so the fetch and the truncation-caption check in
    /// `SearchResultsView` can't drift apart.
    static let searchResultCap = 20

    // MARK: - API source

    private let api: NavidromeAPI

    // MARK: - Init

    public init(api: NavidromeAPI) {
        self.api = api
    }

    // MARK: - Convenience

    /// The API instance provided at init, exposed so views can pass it to
    /// `SubsonicCoverArt` and `AudioPlayerService.play(track:via:)`.
    public var navidromeAPI: NavidromeAPI { api }

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

    // MARK: - Star / rating state (65x.2)

    // NOTE on favorites separation:
    // These star states are for Navidrome music library items (server-side).
    // They are entirely separate from ProviderManager.favoriteOrder, which
    // manages LOCAL radio-channel favorites. Do not mix these domains.

    /// Star state for the current album (loaded via getAlbumWithStarState).
    @Published public private(set) var selectedAlbumStarState: NavidromeAPI.StarState?
    /// Per-track star states for the current album's tracks. Keyed by track ID.
    @Published public private(set) var albumTrackStarStates: [String: NavidromeAPI.StarState] = [:]
    /// Star state for the current artist (loaded via getArtistWithStarState).
    @Published public private(set) var selectedArtistStarState: NavidromeAPI.StarState?
    /// Per-track star states for the current playlist's tracks. Keyed by track ID.
    @Published public private(set) var playlistTrackStarStates: [String: NavidromeAPI.StarState] = [:]

    /// Error message from a recent star/rating operation; surfaces via existing error-alert pattern.
    @Published public private(set) var starError: String? = nil

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

    // MARK: - Playlist list (msl.2)

    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var playlistsState: LoadState = .idle

    // MARK: - Playlist detail (msl.2)

    @Published public private(set) var selectedPlaylist: Playlist?
    @Published public private(set) var playlistTracks: [Track] = []
    @Published public private(set) var playlistTracksState: LoadState = .idle

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

    /// Error message for the most recent playlist edit operation, if any.
    @Published public private(set) var playlistEditError: String? = nil

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

    // MARK: - Reset helpers (0xy.4 additions)

    public func resetBrowseAlbums() {
        browseAlbums = []
        browseAlbumStarStates = [:]
        browseAlbumsState = .idle
        browseAlbumsHasMore = false
    }

    public func resetGenreDetail() {
        selectedGenre = nil
        genreTracks = []
        genreTrackStarStates = [:]
        genreTracksState = .idle
        genreTracksHasMore = false
    }

    // MARK: - Search (1x1.2)

    /// Query string driving the current or last-completed search.
    @Published public private(set) var searchQuery: String = ""
    /// Results from the last completed `search3` call.
    @Published public private(set) var searchResults: NavidromeAPI.SearchResults = .empty
    /// Load state for the search request.
    @Published public private(set) var searchState: LoadState = .idle
    /// Per-album star/play-count states for the most recent search results. (65x.3)
    @Published public private(set) var searchAlbumStarStates: [String: NavidromeAPI.StarState] = [:]
    /// Per-song star/play-count states for the most recent search results. (65x.3)
    @Published public private(set) var searchSongStarStates: [String: NavidromeAPI.StarState] = [:]

    /// In-flight search task — cancelled when a new keystroke arrives.
    private var searchTask: Task<Void, Never>?

    /// Debounce interval for the search field (300 ms).
    private static let searchDebounceNanoseconds: UInt64 = 300_000_000

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

    // MARK: - Reset helpers

    public func resetArtistDetail() {
        selectedArtist = nil
        artistAlbums = []
        albumsState = .idle
        selectedArtistStarState = nil
    }

    public func resetAlbumDetail() {
        selectedAlbum = nil
        selectedAlbumArtistName = nil
        albumTracks = []
        tracksState = .idle
        selectedAlbumStarState = nil
        albumTrackStarStates = [:]
    }
}

// MARK: - LoadState

public enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}

// MARK: - Pagination decisions (uxc.2)

/// Pure load-more decision logic for offset-paginated browse lists (album
/// browse, genre tracks) and the search-truncation caption. Extracted so the
/// "is there probably more" / "should this fetch another page" logic is
/// testable without the network — Subsonic's `getAlbumList2`/`getSongsByGenre`
/// don't return a total count, so a full page is the only load-more signal
/// available.
public enum BrowsePagination {
    /// A full page (returned count >= what was asked for) suggests more may
    /// exist server-side. `requestedPageSize <= 0` never has more.
    public static func hasMore(returnedCount: Int, requestedPageSize: Int) -> Bool {
        requestedPageSize > 0 && returnedCount >= requestedPageSize
    }

    /// Whether rendering `itemID` in an infinite-scroll list should trigger a
    /// load-more fetch: only the last item in the current list, only when
    /// more pages are believed to exist, and only when a fetch isn't already
    /// in flight (guards against duplicate concurrent fetches as the list
    /// re-renders).
    public static func shouldLoadMore(itemID: String, lastItemID: String?, hasMore: Bool, isLoadingMore: Bool) -> Bool {
        hasMore && !isLoadingMore && itemID == lastItemID
    }
}
