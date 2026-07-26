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
    @EnvironmentObject private var downloadManager: DownloadManager

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
                "Save Error",
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
        LoadableContent(
            state: viewModel.tracksState,
            loadingText: "Loading tracks…",
            emptyTitle: "No Tracks",
            emptySystemImage: "music.note",
            emptyDescription: "\(album.title) has no tracks in your library.",
            errorTitle: "Couldn't Load Tracks",
            retry: { Task { await viewModel.loadTracks(for: album) } }
        ) {
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
                        leading: .trackNumber(track.trackNumber),
                        subtitle: nil,   // bug sbx: artist is in the header
                        onPlay: { play(track: track) }
                    )
                    .accessibilityLabel(trackAccessibilityLabel(track))
                    .accessibilityHint("Tap to play")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        loveButton(for: track)
                        downloadSwipeButton(for: track)
                    }
                    .contextMenu {
                        Button {
                            trackForAddToPlaylist = track
                        } label: {
                            Label("Add to Playlist…", systemImage: "music.note.list")
                        }
                        .accessibilityLabel("Add \(track.title) to a playlist")
                        loveButton(for: track)
                        downloadContextMenuItem(for: track)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var albumHeader: some View {
        VStack(spacing: 12) {
            // 15c: Star toggle + Download All on one row, above the art.
            HStack(spacing: 16) {
                NavidromeStarButton(
                    starred: viewModel.selectedAlbumStarState?.starred ?? false,
                    accessibilityLabel: "Save \(album.title)"
                ) {
                    Task { await viewModel.toggleStar(id: album.id) }
                }

                if !viewModel.albumTracks.isEmpty {
                    AlbumDownloadAllButton(
                        tracks: viewModel.albumTracks,
                        api: api
                    )
                }
            }

            // uxd.4: no longer blanket-hidden — SubsonicCoverArt manages its
            // own accessibilityHidden state so the failed-load retry button
            // stays reachable (see SubsonicCoverArt.swift).
            SubsonicCoverArt(
                api: api,
                coverArtID: album.coverArt,
                size: 600,
                width: 200,
                height: 200,
                cornerRadius: 12
            )

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

    /// Save (star) toggle used in both the swipe action and the long-press menu
    /// (bug sbx — moved off the row to free title width).
    @ViewBuilder
    private func loveButton(for track: Track) -> some View {
        let starred = viewModel.albumTrackStarStates[track.id]?.starred ?? false
        Button {
            Task { await viewModel.toggleStar(id: track.id) }
        } label: {
            Label(starred ? "Remove from Saved" : "Save",
                  systemImage: starred ? "heart.slash" : "heart")
        }
        .tint(.pink)
        .accessibilityLabel(starred ? "Remove \(track.title) from Saved" : "Save \(track.title)")
    }

    /// Download affordance for the swipe action — mirrors `downloadContextMenuItem`
    /// but with swipe tints (bug sbx).
    @ViewBuilder
    private func downloadSwipeButton(for track: Track) -> some View {
        let record = downloadManager.downloads.first { $0.id == track.id }
        switch record?.status {
        case .none, .failed, .paused:
            Button {
                downloadManager.download(track: track, via: api)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(.blue)
            .accessibilityLabel("Download \(track.title)")
        case .queued, .downloading:
            Button {
                downloadManager.cancelDownload(trackID: track.id)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .tint(.orange)
            .accessibilityLabel("Cancel download of \(track.title)")
        case .completed:
            Button(role: .destructive) {
                downloadManager.deleteDownload(trackID: track.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove downloaded \(track.title)")
        }
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

// MARK: - Album download-all button (l31.2)

/// Header-level "Download All" / "Downloaded" affordance for an album.
/// Shows aggregate state across all tracks.
struct AlbumDownloadAllButton: View {
    let tracks: [Track]
    let api: NavidromeAPI

    @EnvironmentObject private var downloadManager: DownloadManager

    private var aggregateState: AggregateDownloadState {
        let statuses = tracks.map { track in
            downloadManager.downloads.first(where: { $0.id == track.id })?.status
        }
        return AggregateDownloadState.derive(statuses: statuses)
    }

    var body: some View {
        switch aggregateState {
        case .allDownloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
                .accessibilityLabel("All tracks downloaded")
                .accessibilityValue("Downloaded")

        case .downloading(let completed, let total, let failed):
            Button {
                enqueueAll()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Downloading \(completed) of \(total)", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.linear)
                    // Distinguishes "stalled on errors" from "still in progress"
                    // (beads_mobilemusic-uxc kickback) — matches TrackDownloadButton's
                    // failed vocabulary (exclamationmark.circle, orange).
                    if failed > 0 {
                        Label("\(failed) failed", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Downloading \(completed) of \(total) tracks" + (failed > 0 ? ", \(failed) failed" : ""))
            .accessibilityValue("\(completed) of \(total) complete" + (failed > 0 ? ", \(failed) failed" : ""))

        case .none:
            Button {
                enqueueAll()
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Download all tracks in this album")
        }
    }

    private func enqueueAll() {
        for track in tracks {
            downloadManager.download(track: track, via: api)
        }
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
    .environmentObject(DownloadManager.shared)
}
#endif // canImport(UIKit)
