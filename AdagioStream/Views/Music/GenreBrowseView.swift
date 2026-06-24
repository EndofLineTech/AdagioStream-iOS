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
        switch viewModel.genresState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading genres…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Genres",
                    systemImage: "music.quarternote.3",
                    description: "Your Navidrome library has no genre tags yet."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Genres",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadGenres() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
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

    var body: some View {
        content
            .navigationTitle(genre.name)
            .navigationBarTitleDisplayMode(.large)
            .task {
                if viewModel.selectedGenre?.name != genre.name {
                    await viewModel.loadTracks(forGenre: genre)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.genreTracksState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading songs…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Songs",
                    systemImage: "music.note",
                    description: "No songs found for the \"\(genre.name)\" genre."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Songs",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadTracks(forGenre: genre) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            trackList
        }
    }

    private var trackList: some View {
        // Capture genre tracks once per render so the index lookup is stable
        // when the closure fires.
        let tracks = viewModel.genreTracks
        return List {
            ForEach(tracks, id: \.id) { track in
                GenreTrackRowView(track: track, api: api) {
                    // d6q.1: enqueue the full genre song list starting at the
                    // tapped track so next/previous steps through the genre.
                    // Artist display name: Track only carries artistId in v1
                    // schema; pass nil so the player falls back gracefully.
                    let startIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
                    audioPlayer.setQueue(tracks, startIndex: startIndex, displayArtistName: nil, via: api)
                }
                .accessibilityLabel(genreTrackAccessibilityLabel(track))
                .accessibilityHint("Tap to play")
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
        return parts.joined(separator: ", ")
    }
}

// MARK: - Genre track row

struct GenreTrackRowView: View {
    let track: Track
    let api: NavidromeAPI
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Cover art thumbnail (small, for visual variety in genre lists)
            SubsonicCoverArt(
                api: api,
                coverArtID: track.coverArt,
                size: 80,
                width: 40,
                height: 40,
                cornerRadius: 6
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let genre = track.genre {
                    Text(genre)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let duration = track.duration {
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }

            Button {
                onPlay()
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
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
