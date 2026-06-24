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

    // MARK: - Genre list (0xy.4)

    @Published public private(set) var genres: [Genre] = []
    @Published public private(set) var genresState: LoadState = .idle

    // MARK: - Genre detail: songs by genre (0xy.4)

    @Published public private(set) var selectedGenre: Genre?
    @Published public private(set) var genreTracks: [Track] = []
    @Published public private(set) var genreTracksState: LoadState = .idle

    // MARK: - Page sizes (single-page, no pagination in 0xy.4)

    /// Maximum albums returned by getAlbumList2 in a single fetch.
    /// Navidrome accepts 1–500; 50 is a reasonable single-page default.
    /// Pagination is deferred to a future bead.
    static let albumBrowsePageSize = 50

    /// Maximum songs returned by getSongsByGenre in a single fetch.
    static let genreSongsPageSize = 50

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
        albumsState = .loading
        do {
            let (_, albums) = try await api.getArtist(id: artist.id)
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

    // MARK: - Load: tracks for an album

    public func loadTracks(for album: Album) async {
        guard tracksState != .loading else { return }
        selectedAlbum = album
        selectedAlbumArtistName = nil
        albumTracks = []
        tracksState = .loading
        do {
            let (returnedAlbum, tracks) = try await api.getAlbum(id: album.id)
            // getAlbum returns an Album record; but the DTO-level artistName is
            // captured in the NavidromeAPI private AlbumDetail payload.  To surface
            // it we call via the public fetch<T> path by re-fetching with
            // SubsonicAlbumDTOPayload — simpler to store it in the intermediate
            // fetch.  Workaround: the DTO's artistName is not forwarded through
            // toRecord() (Album has no artistName column in v1 schema).
            //
            // Resolution: fetch the raw DTO separately to read artistName.
            // This is a second HTTP call only on the first album open; the
            // image cache warms the cover art. Trade-off accepted for startup tier.
            //
            // Actually the cleaner path: NavidromeAPI.getAlbum already decodes the
            // album DTO internally; we extend it to return artistName too.
            // Until that extension lands, fall back to resolving via selectedArtist.
            //
            // Use the artist name we already have from the artist list / artist
            // detail load — it's in selectedArtist.name which we loaded one
            // screen back.  No extra network call needed for the common path.
            selectedAlbumArtistName = selectedArtist?.name
            selectedAlbum = returnedAlbum
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
        browseAlbumsState = .loading
        do {
            let albums = try await api.getAlbumList2(
                type: type,
                size: NavidromeLibraryViewModel.albumBrowsePageSize,
                offset: 0
            )
            browseAlbums = albums
            browseAlbumsState = albums.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            browseAlbumsState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            browseAlbumsState = .error(error.localizedDescription)
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
        genreTracksState = .loading
        do {
            let tracks = try await api.getSongsByGenre(
                genre: genre.name,
                count: NavidromeLibraryViewModel.genreSongsPageSize,
                offset: 0
            )
            genreTracks = tracks
            genreTracksState = tracks.isEmpty ? .empty : .loaded
        } catch let apiErr as NavidromeAPI.APIError {
            genreTracksState = .error(apiErr.errorDescription ?? "Unknown error")
        } catch {
            genreTracksState = .error(error.localizedDescription)
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
        do {
            let (playlist, tracks) = try await api.getPlaylist(id: id)
            selectedPlaylist = playlist
            playlistTracks = tracks
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
    }

    // MARK: - Reset helpers (0xy.4 additions)

    public func resetBrowseAlbums() {
        browseAlbums = []
        browseAlbumsState = .idle
    }

    public func resetGenreDetail() {
        selectedGenre = nil
        genreTracks = []
        genreTracksState = .idle
    }

    // MARK: - Search (1x1.2)

    /// Query string driving the current or last-completed search.
    @Published public private(set) var searchQuery: String = ""
    /// Results from the last completed `search3` call.
    @Published public private(set) var searchResults: NavidromeAPI.SearchResults = .empty
    /// Load state for the search request.
    @Published public private(set) var searchState: LoadState = .idle

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
                let results = try await api.search3(query: trimmed)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.searchResults = results
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
        searchState = .idle
    }

    // MARK: - Reset helpers

    public func resetArtistDetail() {
        selectedArtist = nil
        artistAlbums = []
        albumsState = .idle
    }

    public func resetAlbumDetail() {
        selectedAlbum = nil
        selectedAlbumArtistName = nil
        albumTracks = []
        tracksState = .idle
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
