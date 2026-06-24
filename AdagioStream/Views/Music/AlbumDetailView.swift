// 0xy.3 — Navidrome browse UI: album → tracks + tap-to-play
// 65x.2 — Star/unstar toggle for album header and track rows; rating control
//
// Shows tracks for a single album with a header (cover art + title + artist).
// Tapping a track row OR the play button enqueues the WHOLE ALBUM as a queue
// starting at the tapped track (d6q.1).  Calls
// AudioPlayerService.setQueue(_:startIndex:displayArtistName:via:) so the
// entire album is loaded into the queue and next/previous navigation works
// across tracks without returning to this view.
// The selectedAlbumArtistName from the view model is threaded through so the
// now-playing / mini-player subtitle shows the human artist name, not artistId.

#if canImport(UIKit)
import SwiftUI

struct AlbumDetailView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let album: Album
    let api: NavidromeAPI

    @EnvironmentObject private var audioPlayer: AudioPlayerService

    @State private var trackForAddToPlaylist: Track?

    var body: some View {
        content
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if viewModel.selectedAlbum?.id != album.id {
                    await viewModel.loadTracks(for: album)
                }
            }
            .sheet(item: $trackForAddToPlaylist) { track in
                NavidromeAddToPlaylistSheet(
                    track: track,
                    viewModel: viewModel,
                    api: api
                )
            }
            .alert(
                "Star Error",
                isPresented: Binding(
                    get: { viewModel.starError != nil },
                    set: { if !$0 { viewModel.clearStarError() } }
                )
            ) {
                Button("OK") { viewModel.clearStarError() }
            } message: {
                Text(viewModel.starError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.tracksState {
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
                    title: "No Tracks",
                    systemImage: "music.note",
                    description: "\(album.title) has no tracks in your library."
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
                        Task { await viewModel.loadTracks(for: album) }
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
            // Album header
            Section {
                albumHeader
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())

            // Track rows
            Section {
                ForEach(viewModel.albumTracks, id: \.id) { track in
                    TrackRowView(
                        track: track,
                        artistName: viewModel.selectedAlbumArtistName,
                        onPlay: { play(track: track) },
                        starred: viewModel.albumTrackStarStates[track.id]?.starred,
                        onToggleStar: {
                            Task { await viewModel.toggleStar(id: track.id) }
                        }
                    )
                    .accessibilityLabel(trackAccessibilityLabel(track))
                    .accessibilityHint("Tap to play")
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
        }
        .listStyle(.insetGrouped)
    }

    private var albumHeader: some View {
        VStack(spacing: 12) {
            SubsonicCoverArt(
                api: api,
                coverArtID: album.coverArt,
                size: 600,
                width: 200,
                height: 200,
                cornerRadius: 12
            )
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(album.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                if let artistName = viewModel.selectedAlbumArtistName {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let year = album.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // 65x.2: Album star toggle
                NavidromeStarButton(
                    starred: viewModel.selectedAlbumStarState?.starred ?? false,
                    accessibilityLabel: "Star \(album.title)"
                ) {
                    Task { await viewModel.toggleStar(id: album.id) }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func play(track: Track) {
        // d6q.1: enqueue the whole album starting at the tapped track so
        // next/previous navigate through all tracks in track-number order.
        let tracks = viewModel.albumTracks
        let startIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        audioPlayer.setQueue(
            tracks,
            startIndex: startIndex,
            displayArtistName: viewModel.selectedAlbumArtistName,
            via: api
        )
    }

    private func trackAccessibilityLabel(_ track: Track) -> String {
        var parts: [String] = []
        if let number = track.trackNumber {
            parts.append("Track \(number)")
        }
        parts.append(track.title)
        if let name = viewModel.selectedAlbumArtistName {
            parts.append("by \(name)")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Track row

struct TrackRowView: View {
    let track: Track
    let artistName: String?
    let onPlay: () -> Void
    /// 65x.2: When non-nil the row shows a heart button reflecting starred state.
    var starred: Bool? = nil
    /// 65x.2: Called when the heart button is tapped.
    var onToggleStar: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Track number badge
            Group {
                if let number = track.trackNumber {
                    Text(String(number))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                } else {
                    Spacer()
                        .frame(width: 28)
                }
            }
            .accessibilityHidden(true)

            // Title + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let name = artistName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

            // 65x.2: Star toggle — shown when star state is available
            if let isStarred = starred, let toggle = onToggleStar {
                NavidromeStarButton(
                    starred: isStarred,
                    accessibilityLabel: isStarred ? "Unstar \(track.title)" : "Star \(track.title)",
                    onToggle: toggle
                )
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

#Preview {
    let api = NavidromeAPI(
        host: URL(string: "https://demo.navidrome.org")!,
        username: "demo",
        password: "demo"
    )
    let vm = NavidromeLibraryViewModel(api: api)
    return NavigationStack {
        AlbumDetailView(
            viewModel: vm,
            album: Album(
                id: "1",
                artistId: "art-1",
                title: "Blue Lines",
                year: 1991,
                updatedAt: 0
            ),
            api: api
        )
    }
    .environmentObject(AudioPlayerService.shared)
}
#endif // canImport(UIKit)
