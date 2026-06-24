// msl.2 — Navidrome playlist browse + play-as-queue in Music tab
//
// Two-level navigation:
//   PlaylistListView  (fetches getPlaylists, shows name + song count + cover art)
//     └── PlaylistDetailView  (fetches getPlaylist(id:), shows header + track list)
//
// Track playback: tapping a row calls
//   audioPlayer.setQueue(tracks, startIndex: index, displayArtistName: nil, via: api)
// so the entire playlist is loaded as the queue and next/previous navigation works
// across all tracks without returning to this view.
//
// A "Play" toolbar button enqueues from track 0.
// A "Shuffle" toolbar button toggles shuffle then enqueues from track 0.
//
// Loading / empty / error states mirror the existing album and genre browse screens.
// EmptyStateView is reused for empty and error conditions.

#if canImport(UIKit)
import SwiftUI

// MARK: - Playlist list

struct PlaylistListView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let api: NavidromeAPI

    var body: some View {
        content
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.large)
            .task {
                if viewModel.playlistsState == .idle {
                    await viewModel.loadPlaylists()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.playlistsState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading playlists…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Playlists",
                    systemImage: "music.note.list",
                    description: "Your Navidrome library has no playlists yet."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Playlists",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadPlaylists() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            playlistList
        }
    }

    private var playlistList: some View {
        List(viewModel.playlists, id: \.id) { playlist in
            NavigationLink {
                PlaylistDetailView(
                    viewModel: viewModel,
                    playlist: playlist,
                    api: api
                )
            } label: {
                PlaylistRowView(playlist: playlist, api: api)
            }
            .accessibilityLabel(playlist.name)
            .accessibilityHint(
                "\(playlist.songCount) \(playlist.songCount == 1 ? "song" : "songs")"
            )
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.loadPlaylists()
        }
    }
}

// MARK: - Playlist row

struct PlaylistRowView: View {
    let playlist: Playlist
    let api: NavidromeAPI

    var body: some View {
        HStack(spacing: 12) {
            SubsonicCoverArt(
                api: api,
                coverArtID: playlist.coverArt,
                size: 80,
                width: 44,
                height: 44,
                cornerRadius: 8
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(
                    "\(playlist.songCount) \(playlist.songCount == 1 ? "song" : "songs")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let playlist: Playlist
    let api: NavidromeAPI

    @EnvironmentObject private var audioPlayer: AudioPlayerService

    var body: some View {
        content
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .loaded = viewModel.playlistTracksState,
                   !viewModel.playlistTracks.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            shuffleAndPlay()
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .accessibilityLabel("Shuffle playlist")

                        Button {
                            playFromStart()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .accessibilityLabel("Play playlist from beginning")
                    }
                }
            }
            .task {
                if viewModel.selectedPlaylist?.id != playlist.id {
                    viewModel.resetPlaylistDetail()
                    await viewModel.loadPlaylist(id: playlist.id)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.playlistTracksState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading tracks…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "Empty Playlist",
                    systemImage: "music.note.list",
                    description: "\"\(playlist.name)\" has no tracks yet."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Tracks",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadPlaylist(id: playlist.id) }
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
        List {
            // Playlist header
            Section {
                playlistHeader
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())

            // Track rows
            Section {
                let tracks = viewModel.playlistTracks
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    PlaylistTrackRowView(
                        track: track,
                        position: index + 1
                    ) {
                        play(track: track)
                    }
                    .accessibilityLabel(playlistTrackAccessibilityLabel(track, position: index + 1))
                    .accessibilityHint("Tap to play")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.loadPlaylist(id: playlist.id)
        }
    }

    private var playlistHeader: some View {
        VStack(spacing: 12) {
            SubsonicCoverArt(
                api: api,
                coverArtID: playlist.coverArt,
                size: 600,
                width: 200,
                height: 200,
                cornerRadius: 12
            )
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                let songWord = playlist.songCount == 1 ? "song" : "songs"
                Text("\(playlist.songCount) \(songWord) · \(formatDuration(playlist.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Playback actions

    private func play(track: Track) {
        let tracks = viewModel.playlistTracks
        let startIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        audioPlayer.setQueue(
            tracks,
            startIndex: startIndex,
            displayArtistName: nil,
            via: api
        )
    }

    private func playFromStart() {
        let tracks = viewModel.playlistTracks
        guard !tracks.isEmpty else { return }
        audioPlayer.setQueue(tracks, startIndex: 0, displayArtistName: nil, via: api)
    }

    private func shuffleAndPlay() {
        let tracks = viewModel.playlistTracks
        guard !tracks.isEmpty else { return }
        if !audioPlayer.shuffleEnabled {
            audioPlayer.toggleShuffle()
        }
        audioPlayer.setQueue(tracks, startIndex: 0, displayArtistName: nil, via: api)
    }

    // MARK: - Helpers

    private func playlistTrackAccessibilityLabel(_ track: Track, position: Int) -> String {
        var parts: [String] = []
        parts.append("Track \(position)")
        parts.append(track.title)
        return parts.joined(separator: ", ")
    }

    private func formatDuration(_ seconds: Int) -> String {
        let totalMinutes = seconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        } else {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            if mins == 0 {
                return "\(hours) hr"
            } else {
                return "\(hours) hr \(mins) min"
            }
        }
    }
}

// MARK: - Playlist track row

struct PlaylistTrackRowView: View {
    let track: Track
    let position: Int
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Position badge
            Text(String(position))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)

            // Title
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            if let duration = track.duration {
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }

            // Play button
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

#Preview("Playlist List") {
    let api = NavidromeAPI(
        host: URL(string: "https://demo.navidrome.org")!,
        username: "demo",
        password: "demo"
    )
    return NavigationStack {
        PlaylistListView(
            viewModel: NavidromeLibraryViewModel(api: api),
            api: api
        )
    }
    .environmentObject(AudioPlayerService.shared)
}
#endif // canImport(UIKit)
