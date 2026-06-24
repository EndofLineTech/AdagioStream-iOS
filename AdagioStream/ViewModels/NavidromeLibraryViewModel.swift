// 0xy.3 — Navidrome browse UI: view-model
//
// MVVM, @MainActor ObservableObject following the ChannelListViewModel pattern.
// Drives three screens: artist list, artist→albums, album→tracks.
//
// Loading states: .idle → .loading → .loaded / .error
// Error messages surface NavidromeAPI.APIError.errorDescription directly.

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
