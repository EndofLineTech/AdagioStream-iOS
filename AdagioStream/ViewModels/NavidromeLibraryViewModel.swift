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
//
// beads_mobilemusic-01a — decomposed into per-domain extension files
// (NavidromeLibraryViewModel+*.swift). All @Published state stays declared
// here: Swift extensions cannot add stored properties to a type, so the
// per-domain load/reset/toggle logic that used to sit next to each property
// now lives in its own file while the storage remains in this one. `api`
// and the @Published properties above are promoted from `private`/
// `private(set)` to (implicit) `internal`/`internal(set)` — Swift's
// `private` access level is file-scoped even across extensions of the same
// type, so a setter used from a sibling file needs at least module-internal
// access. The public surface (getters, method signatures) is unchanged.

import Foundation

@MainActor
public final class NavidromeLibraryViewModel: ObservableObject {

    // MARK: - Artist list

    @Published public internal(set) var artists: [Artist] = []
    @Published public internal(set) var artistsState: LoadState = .idle

    // MARK: - Artist detail (albums)

    @Published public internal(set) var selectedArtist: Artist?
    @Published public internal(set) var artistAlbums: [Album] = []
    @Published public internal(set) var albumsState: LoadState = .idle

    // MARK: - Album detail (tracks)

    @Published public internal(set) var selectedAlbum: Album?
    /// Artist display name sourced from the `SubsonicAlbumDTO.artistName` field.
    /// Non-nil when the album detail response includes it; used to show the
    /// human name instead of `artistId` in the track list and now-playing.
    @Published public internal(set) var selectedAlbumArtistName: String?
    @Published public internal(set) var albumTracks: [Track] = []
    @Published public internal(set) var tracksState: LoadState = .idle

    // MARK: - Browse albums by type (0xy.4)

    /// The last album-list type that was successfully fetched (or is loading).
    @Published public internal(set) var browseAlbumsType: NavidromeAPI.AlbumListType = .newest
    @Published public internal(set) var browseAlbums: [Album] = []
    @Published public internal(set) var browseAlbumsState: LoadState = .idle
    /// Per-album star/play-count states for the current browse-albums page.
    /// Keyed by album ID. Populated alongside browseAlbums on each load. (65x.3)
    @Published public internal(set) var browseAlbumStarStates: [String: NavidromeAPI.StarState] = [:]
    /// True when the last fetched page was full-size, meaning more albums may
    /// exist server-side (uxc.2 — scroll-driven load-more).
    @Published public internal(set) var browseAlbumsHasMore = false
    /// True while a load-more fetch (not the initial page) is in flight.
    @Published public internal(set) var isLoadingMoreBrowseAlbums = false

    // MARK: - Genre list (0xy.4)

    @Published public internal(set) var genres: [Genre] = []
    @Published public internal(set) var genresState: LoadState = .idle

    // MARK: - Genre detail: songs by genre (0xy.4)

    @Published public internal(set) var selectedGenre: Genre?
    @Published public internal(set) var genreTracks: [Track] = []
    @Published public internal(set) var genreTracksState: LoadState = .idle
    /// Per-song star/play-count states for the current genre track page.
    /// Keyed by track ID. Populated alongside genreTracks on each load. (65x.3)
    @Published public internal(set) var genreTrackStarStates: [String: NavidromeAPI.StarState] = [:]
    /// True when the last fetched page was full-size, meaning more songs may
    /// exist server-side (uxc.2 — scroll-driven load-more).
    @Published public internal(set) var genreTracksHasMore = false
    /// True while a load-more fetch (not the initial page) is in flight.
    @Published public internal(set) var isLoadingMoreGenreTracks = false

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

    let api: NavidromeAPI

    // MARK: - Init

    public init(api: NavidromeAPI) {
        self.api = api
    }

    // MARK: - Convenience

    /// The API instance provided at init, exposed so views can pass it to
    /// `SubsonicCoverArt` and `AudioPlayerService.play(track:via:)`.
    public var navidromeAPI: NavidromeAPI { api }

    // MARK: - Star / rating state (65x.2)

    // NOTE on favorites separation:
    // These star states are for Navidrome music library items (server-side).
    // They are entirely separate from ProviderManager.favoriteOrder, which
    // manages LOCAL radio-channel favorites. Do not mix these domains.

    /// Star state for the current album (loaded via getAlbumWithStarState).
    @Published public internal(set) var selectedAlbumStarState: NavidromeAPI.StarState?
    /// Per-track star states for the current album's tracks. Keyed by track ID.
    @Published public internal(set) var albumTrackStarStates: [String: NavidromeAPI.StarState] = [:]
    /// Star state for the current artist (loaded via getArtistWithStarState).
    @Published public internal(set) var selectedArtistStarState: NavidromeAPI.StarState?
    /// Per-track star states for the current playlist's tracks. Keyed by track ID.
    @Published public internal(set) var playlistTrackStarStates: [String: NavidromeAPI.StarState] = [:]

    /// Error message from a recent star/rating operation; surfaces via existing error-alert pattern.
    @Published public internal(set) var starError: String? = nil

    // MARK: - Playlist list (msl.2)

    @Published public internal(set) var playlists: [Playlist] = []
    @Published public internal(set) var playlistsState: LoadState = .idle

    // MARK: - Playlist detail (msl.2)

    @Published public internal(set) var selectedPlaylist: Playlist?
    @Published public internal(set) var playlistTracks: [Track] = []
    @Published public internal(set) var playlistTracksState: LoadState = .idle

    // MARK: - Playlist editing error (msl.3)

    /// Error message for the most recent playlist edit operation, if any.
    @Published public internal(set) var playlistEditError: String? = nil

    // MARK: - Search (1x1.2)

    /// Query string driving the current or last-completed search.
    @Published public internal(set) var searchQuery: String = ""
    /// Results from the last completed `search3` call.
    @Published public internal(set) var searchResults: NavidromeAPI.SearchResults = .empty
    /// Load state for the search request.
    @Published public internal(set) var searchState: LoadState = .idle
    /// Per-album star/play-count states for the most recent search results. (65x.3)
    @Published public internal(set) var searchAlbumStarStates: [String: NavidromeAPI.StarState] = [:]
    /// Per-song star/play-count states for the most recent search results. (65x.3)
    @Published public internal(set) var searchSongStarStates: [String: NavidromeAPI.StarState] = [:]

    /// In-flight search task — cancelled when a new keystroke arrives.
    var searchTask: Task<Void, Never>?

    /// Debounce interval for the search field (300 ms).
    static let searchDebounceNanoseconds: UInt64 = 300_000_000
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
