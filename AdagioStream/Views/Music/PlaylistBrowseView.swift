// msl.2 — Navidrome playlist browse + play-as-queue in Music tab
// msl.3 — Playlist editing: create / delete / rename / remove tracks / add-to-playlist
// 65x.2 — Star/unstar toggle on playlist track rows
//
// Two-level navigation:
//   PlaylistListView  (fetches getPlaylists, shows name + song count + cover art)
//     └── PlaylistDetailView  (fetches getPlaylist(id:), shows header + track list)
//
// Editing affordances:
//   PlaylistListView:
//     • "+" toolbar button → create new playlist (alert with name field)
//     • Swipe-to-delete on a row → confirm → deletePlaylist
//
//   PlaylistDetailView:
//     • Toolbar "Rename" → rename alert
//     • Edit mode → swipe-to-delete on track rows → removeTracksFromPlaylist (by index)
//     • Track context menu → "Add to Playlist" → NavidromeAddToPlaylistSheet
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

    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var playlistToDelete: Playlist?
    @State private var showDeleteConfirm = false
    @State private var isCreating = false

    var body: some View {
        content
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newPlaylistName = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New playlist")
                    .disabled(isCreating)
                }
            }
            .task {
                if viewModel.playlistsState == .idle {
                    await viewModel.loadPlaylists()
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                    .autocorrectionDisabled()
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        isCreating = true
                        await viewModel.createPlaylist(name: name)
                        isCreating = false
                    }
                }
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("Enter a name for the new playlist.")
            }
            .confirmationDialog(
                "Delete \"\(playlistToDelete?.name ?? "")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Playlist", role: .destructive) {
                    guard let playlist = playlistToDelete else { return }
                    Task { await viewModel.deletePlaylist(id: playlist.id) }
                }
                Button("Cancel", role: .cancel) {
                    playlistToDelete = nil
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { viewModel.playlistEditError != nil },
                    set: { if !$0 { viewModel.clearPlaylistEditError() } }
                )
            ) {
                Button("OK") { viewModel.clearPlaylistEditError() }
            } message: {
                Text(viewModel.playlistEditError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        LoadableContent(
            state: viewModel.playlistsState,
            loadingText: "Loading playlists…",
            emptyTitle: "No Playlists",
            emptySystemImage: "music.note.list",
            emptyDescription: "Tap + to create your first playlist.",
            errorTitle: "Couldn't Load Playlists",
            retry: { Task { await viewModel.loadPlaylists() } }
        ) {
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    playlistToDelete = playlist
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityLabel("Delete \(playlist.name)")
            }
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
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var isEditingTracks = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var trackForAddToPlaylist: Track?

    var body: some View {
        content
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .task {
                if viewModel.selectedPlaylist?.id != playlist.id {
                    viewModel.resetPlaylistDetail()
                    await viewModel.loadPlaylist(id: playlist.id)
                }
            }
            .alert("Rename Playlist", isPresented: $showRenameAlert) {
                TextField("Playlist name", text: $renameText)
                    .autocorrectionDisabled()
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await viewModel.renamePlaylist(id: playlist.id, newName: name) }
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    renameText = playlist.name
                }
            } message: {
                Text("Enter a new name for the playlist.")
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { viewModel.playlistEditError != nil },
                    set: { if !$0 { viewModel.clearPlaylistEditError() } }
                )
            ) {
                Button("OK") { viewModel.clearPlaylistEditError() }
            } message: {
                Text(viewModel.playlistEditError ?? "")
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .loaded = viewModel.playlistTracksState,
           !viewModel.playlistTracks.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                if !isEditingTracks {
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

        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                renameText = viewModel.selectedPlaylist?.name ?? playlist.name
                showRenameAlert = true
            } label: {
                Label("Rename Playlist", systemImage: "pencil")
            }
            .accessibilityLabel("Rename playlist")

            if case .loaded = viewModel.playlistTracksState,
               !viewModel.playlistTracks.isEmpty {
                Button {
                    isEditingTracks.toggle()
                } label: {
                    Label(
                        isEditingTracks ? "Done Editing" : "Edit Tracks",
                        systemImage: isEditingTracks ? "checkmark.circle" : "list.bullet"
                    )
                }
                .accessibilityLabel(isEditingTracks ? "Done editing tracks" : "Edit tracks")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        LoadableContent(
            state: viewModel.playlistTracksState,
            loadingText: "Loading tracks…",
            emptyTitle: "Empty Playlist",
            emptySystemImage: "music.note.list",
            emptyDescription: "\"\(playlist.name)\" has no tracks yet.",
            errorTitle: "Couldn't Load Tracks",
            retry: { Task { await viewModel.loadPlaylist(id: playlist.id) } }
        ) {
            trackList
        }
    }

    private var trackList: some View {
        List {
            // Playlist header (hidden in edit mode to keep focus on tracks)
            if !isEditingTracks {
                Section {
                    playlistHeader
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }

            // Track rows
            Section {
                let tracks = viewModel.playlistTracks
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRowView(
                        track: track,
                        leading: .position(index + 1),
                        starred: viewModel.playlistTrackStarStates[track.id]?.starred,
                        onToggleStar: {
                            Task { await viewModel.toggleStar(id: track.id) }
                        },
                        downloadAPI: api,
                        showsInlinePlayButton: true,
                        onPlay: { play(track: track) }
                    )
                    .accessibilityLabel(playlistTrackAccessibilityLabel(track, position: index + 1))
                    .accessibilityHint(isEditingTracks ? "Swipe to remove from playlist" : "Tap to play")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if isEditingTracks {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.removeTracksFromPlaylist(
                                        playlistId: playlist.id,
                                        indexes: [index]
                                    )
                                }
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            .accessibilityLabel("Remove \(track.title) from playlist")
                        }
                    }
                    .contextMenu {
                        Button {
                            trackForAddToPlaylist = track
                        } label: {
                            Label("Add to Playlist…", systemImage: "music.note.list")
                        }
                        .accessibilityLabel("Add \(track.title) to a playlist")
                        downloadContextMenuItem(for: track)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, isEditingTracks ? .constant(.active) : .constant(.inactive))
        .refreshable {
            await viewModel.loadPlaylist(id: playlist.id)
        }
    }

    private var playlistHeader: some View {
        VStack(spacing: 12) {
            // 15c: Download All above the art, matching the album screen.
            if case .loaded = viewModel.playlistTracksState, !viewModel.playlistTracks.isEmpty {
                playlistDownloadAllButton
            }

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
                Text(viewModel.selectedPlaylist?.name ?? playlist.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                let p = viewModel.selectedPlaylist ?? playlist
                let songWord = p.songCount == 1 ? "song" : "songs"
                Text("\(p.songCount) \(songWord) · \(formatDuration(p.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Download actions (l31.2)

    @ViewBuilder
    private var playlistDownloadAllButton: some View {
        let tracks = viewModel.playlistTracks
        let allDownloaded = !tracks.isEmpty &&
            tracks.allSatisfy { downloadManager.isDownloaded(trackID: $0.id) }
        if allDownloaded {
            Label("All Downloaded", systemImage: "checkmark.circle.fill")
                .accessibilityLabel("All tracks downloaded")
        } else {
            Button {
                for track in tracks {
                    downloadManager.download(track: track, via: api)
                }
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
            }
            .accessibilityLabel("Download all tracks in this playlist")
        }
    }

    @ViewBuilder
    private func downloadContextMenuItem(for track: Track) -> some View {
        let record = downloadManager.downloads.first { $0.id == track.id }
        switch record?.status {
        case .none, .failed, .paused:
            Button {
                downloadManager.download(track: track, via: api)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .accessibilityLabel("Download \(track.title)")
        case .queued, .downloading:
            Button {
                downloadManager.cancelDownload(trackID: track.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
            .accessibilityLabel("Cancel download of \(track.title)")
        case .completed:
            Button(role: .destructive) {
                downloadManager.deleteDownload(trackID: track.id)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
            .accessibilityLabel("Remove downloaded \(track.title)")
        }
    }

    // MARK: - Playback actions

    private func play(track: Track) {
        guard !isEditingTracks else { return }
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

// MARK: - Track conformance to Identifiable for sheet(item:)

extension Track: Identifiable {}

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
    .environmentObject(DownloadManager.shared)
}
#endif // canImport(UIKit)
