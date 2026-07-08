// 0xy.4 — Genre browse: genres list → songs by genre → tap to play
//
// Two-level navigation:
//   GenreListView  (fetches getGenres, shows name + song/album counts)
//     └── GenreDetailView  (fetches getSongsByGenre, shows track list)
//
// Track playback uses AudioPlayerService.setQueue(_:startIndex:displayArtistName:via:)
// (d6q.1) so tapping a song enqueues the full genre song list starting at that
// song — next/previous then steps through the genre list.
// Artist name for now-playing: Track only carries artistId in v1 schema;
// displayArtistName is passed as nil — the player falls back to artistId.
//
// Pagination: a single page of NavidromeLibraryViewModel.genreSongsPageSize
// (50) is fetched.  No load-more is implemented in 0xy.4.

#if canImport(UIKit)
import SwiftUI

// MARK: - Genre list

struct GenreListView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let api: NavidromeAPI

    var body: some View {
        content
            .navigationTitle("Genres")
            .navigationBarTitleDisplayMode(.large)
            .task {
                if viewModel.genresState == .idle {
                    await viewModel.loadGenres()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        LoadableContent(
            state: viewModel.genresState,
            loadingText: "Loading genres…",
            emptyTitle: "No Genres",
            emptySystemImage: "music.quarternote.3",
            emptyDescription: "Your Navidrome library has no genre tags yet.",
            errorTitle: "Couldn't Load Genres",
            retry: { Task { await viewModel.loadGenres() } }
        ) {
            genreList
        }
    }

    private var genreList: some View {
        List(viewModel.genres, id: \.name) { genre in
            NavigationLink {
                GenreDetailView(viewModel: viewModel, genre: genre, api: api)
            } label: {
                GenreRowView(genre: genre)
            }
            .accessibilityLabel(genre.name)
            .accessibilityHint("Browse \(genre.songCount) songs in \(genre.name)")
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.loadGenres()
        }
    }
}

// MARK: - Genre row

struct GenreRowView: View {
    let genre: Genre

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(genre.name)
                .font(.body)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                if genre.albumCount > 0 {
                    Text("\(genre.albumCount) \(genre.albumCount == 1 ? "album" : "albums")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if genre.songCount > 0 {
                    if genre.albumCount > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(genre.songCount) \(genre.songCount == 1 ? "song" : "songs")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Genre detail (songs by genre)

struct GenreDetailView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let genre: Genre
    let api: NavidromeAPI

    @EnvironmentObject private var audioPlayer: AudioPlayerService

    // j7d.1: "Add to Playlist" sheet state — mirrors AlbumDetailView/PlaylistDetailView
    @State private var trackForAddToPlaylist: Track?

    var body: some View {
        content
            .navigationTitle(genre.name)
            .navigationBarTitleDisplayMode(.large)
            .task {
                if viewModel.selectedGenre?.name != genre.name {
                    await viewModel.loadTracks(forGenre: genre)
                }
            }
            // j7d.1: "Add to Playlist" sheet — mirrors AlbumDetailView/PlaylistDetailView
            .sheet(item: $trackForAddToPlaylist) { track in
                NavidromeAddToPlaylistSheet(
                    track: track,
                    viewModel: viewModel,
                    api: api
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        LoadableContent(
            state: viewModel.genreTracksState,
            loadingText: "Loading songs…",
            emptyTitle: "No Songs",
            emptySystemImage: "music.note",
            emptyDescription: "No songs found for the \"\(genre.name)\" genre.",
            errorTitle: "Couldn't Load Songs",
            retry: { Task { await viewModel.loadTracks(forGenre: genre) } }
        ) {
            trackList
        }
    }

    private var trackList: some View {
        // Capture genre tracks once per render so the index lookup is stable
        // when the closure fires.
        let tracks = viewModel.genreTracks
        return List {
            ForEach(tracks, id: \.id) { track in
                TrackRowView(
                    track: track,
                    leading: .coverArt(api: api, coverArtID: track.coverArt),
                    subtitle: track.genre,
                    // 65x.3: pass star state for starred indicator
                    starIndicator: viewModel.genreTrackStarStates[track.id]?.starred ?? false,
                    showsInlinePlayButton: true
                ) {
                    // d6q.1: enqueue the full genre song list starting at the
                    // tapped track so next/previous steps through the genre.
                    // Artist display name: Track only carries artistId in v1
                    // schema; pass nil so the player falls back gracefully.
                    let startIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
                    audioPlayer.setQueue(tracks, startIndex: startIndex, displayArtistName: nil, via: api)
                }
                .accessibilityLabel(genreTrackAccessibilityLabel(track))
                .accessibilityHint("Tap to play")
                // j7d.1: "Add to Playlist" context menu — mirrors AlbumDetailView
                .contextMenu {
                    Button {
                        trackForAddToPlaylist = track
                    } label: {
                        Label("Add to Playlist…", systemImage: "music.note.list")
                    }
                    .accessibilityLabel("Add \(track.title) to a playlist")
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.loadTracks(forGenre: genre)
        }
    }

    private func genreTrackAccessibilityLabel(_ track: Track) -> String {
        var parts: [String] = []
        if let number = track.trackNumber {
            parts.append("Track \(number)")
        }
        parts.append(track.title)
        // 65x.3: Include starred/play-count in accessibility label
        let state = viewModel.genreTrackStarStates[track.id]
        if state?.starred == true { parts.append("starred") }
        if let count = state?.playCount, count > 0 {
            parts.append("played \(count) \(count == 1 ? "time" : "times")")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview("Genre List") {
    let api = NavidromeAPI(
        host: URL(string: "https://demo.navidrome.org")!,
        username: "demo",
        password: "demo"
    )
    return NavigationStack {
        GenreListView(
            viewModel: NavidromeLibraryViewModel(api: api),
            api: api
        )
    }
    .environmentObject(AudioPlayerService.shared)
}
#endif // canImport(UIKit)
