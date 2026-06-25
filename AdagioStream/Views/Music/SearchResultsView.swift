// 1x1.2 — Library search UI: sectioned artists / albums / songs results
//
// Displayed by MusicLibraryView when the `.searchable` field has non-empty text.
// Three sections (Artists, Albums, Songs), each visible only when results exist.
//
// Navigation:
//   • Artist row  → ArtistDetailView  (NavigationLink)
//   • Album row   → AlbumDetailView   (NavigationLink)
//   • Song row    → tap / play button → AudioPlayerService.setQueue starting at
//                   the tapped song, full results.songs list as the queue.
//
// States: loading spinner, empty ("No results for …"), error (with retry), results.
//
// Artist name for now-playing: Track only carries artistId in v1 schema;
// displayArtistName is passed as nil — the player falls back gracefully,
// consistent with GenreDetailView.

#if canImport(UIKit)
import SwiftUI

// MARK: - SearchResultsView

struct SearchResultsView: View {

    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let api: NavidromeAPI

    @EnvironmentObject private var audioPlayer: AudioPlayerService

    // j7d.1: "Add to Playlist" sheet state — mirrors AlbumDetailView/PlaylistDetailView
    @State private var trackForAddToPlaylist: Track?

    var body: some View {
        stateContent
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
    private var stateContent: some View {
        switch viewModel.searchState {
        case .idle:
            // Non-empty query debouncing — show a spinner while we wait.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Searching…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Results",
                    systemImage: "magnifyingglass",
                    description: "No results for \"\(viewModel.searchQuery)\""
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Search Failed",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        viewModel.updateSearch(query: viewModel.searchQuery)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            resultsList
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        let results = viewModel.searchResults
        return List {
            // MARK: Artists section
            if !results.artists.isEmpty {
                Section {
                    ForEach(results.artists, id: \.id) { artist in
                        NavigationLink {
                            ArtistDetailView(viewModel: viewModel, artist: artist, api: api)
                        } label: {
                            ArtistRowView(artist: artist, api: api)
                        }
                        .accessibilityLabel("\(artist.name), artist")
                        .accessibilityHint("Opens artist")
                    }
                } header: {
                    Text("Artists")
                        .accessibilityAddTraits(.isHeader)
                }
            }

            // MARK: Albums section
            if !results.albums.isEmpty {
                Section {
                    ForEach(results.albums, id: \.id) { album in
                        NavigationLink {
                            AlbumDetailView(viewModel: viewModel, album: album, api: api)
                        } label: {
                            // 65x.3: Pass star state for starred indicator
                            SearchAlbumRowView(
                                album: album,
                                api: api,
                                starState: viewModel.searchAlbumStarStates[album.id]
                            )
                        }
                        // 65x.3: Accessibility label built inside the row view
                        .accessibilityHint("Opens album")
                    }
                } header: {
                    Text("Albums")
                        .accessibilityAddTraits(.isHeader)
                }
            }

            // MARK: Songs section
            if !results.songs.isEmpty {
                let songs = results.songs
                Section {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                        // 65x.3: Pass star state for starred indicator + play count
                        SearchSongRowView(
                            track: track,
                            api: api,
                            starState: viewModel.searchSongStarStates[track.id]
                        ) {
                            audioPlayer.setQueue(
                                songs,
                                startIndex: index,
                                displayArtistName: nil,
                                via: api
                            )
                        }
                        // 65x.3: Accessibility label built inside the row view
                        .accessibilityHint("Plays song")
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
                } header: {
                    Text("Songs")
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Search album row

/// Compact album row: thumbnail + title + year subtitle.
/// 65x.3: Accepts optional star state to show starred indicator alongside title.
private struct SearchAlbumRowView: View {
    let album: Album
    let api: NavidromeAPI
    /// 65x.3: When non-nil, enables the starred indicator in the title row.
    var starState: NavidromeAPI.StarState? = nil

    var body: some View {
        HStack(spacing: 12) {
            SubsonicCoverArt(
                api: api,
                coverArtID: album.coverArt,
                size: 80,
                width: 44,
                height: 44,
                cornerRadius: 6
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // Title + optional starred indicator
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(album.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let state = starState, state.starred {
                        NavidromeStarIndicator(starred: true)
                    }
                }

                if let year = album.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        // 65x.3: Accessibility label includes starred state
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(searchAlbumAccessibilityLabel)
    }

    private var searchAlbumAccessibilityLabel: String {
        var parts: [String] = ["\(album.title), album"]
        if let state = starState, state.starred { parts.append("starred") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Search song row

/// Song row: thumbnail + title + tap-to-play button.
/// Tapping anywhere on the row (or the button) invokes onPlay.
/// 65x.3: Accepts optional star state to show starred indicator and play count.
private struct SearchSongRowView: View {
    let track: Track
    let api: NavidromeAPI
    /// 65x.3: When non-nil, enables the starred indicator and play-count caption.
    var starState: NavidromeAPI.StarState? = nil
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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
                // Title + optional starred indicator
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let state = starState, state.starred {
                        NavidromeStarIndicator(starred: true)
                    }
                }

                // Duration + optional play count
                HStack(spacing: 6) {
                    if let duration = track.duration {
                        Text(formatDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let playText = navidromePlayCountText(starState?.playCount) {
                        Text(playText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

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
        // 65x.3: Accessibility element for the whole row
        .accessibilityElement(children: .contain)
        .accessibilityLabel(searchSongAccessibilityLabel)
    }

    private var searchSongAccessibilityLabel: String {
        var parts: [String] = ["\(track.title), song"]
        if let state = starState {
            if state.starred { parts.append("starred") }
            if let count = state.playCount, count > 0 {
                parts.append("played \(count) \(count == 1 ? "time" : "times")")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Preview

#Preview("Search Results") {
    let api = NavidromeAPI(
        host: URL(string: "https://demo.navidrome.org")!,
        username: "demo",
        password: "demo"
    )
    return NavigationStack {
        SearchResultsView(
            viewModel: NavidromeLibraryViewModel(api: api),
            api: api
        )
    }
    .environmentObject(AudioPlayerService.shared)
}
#endif // canImport(UIKit)
