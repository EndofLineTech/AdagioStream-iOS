// msl.3 — Reusable "Add to Playlist" picker sheet for Navidrome tracks
//
// Presents the user's Navidrome playlists so they can pick one to add a track
// to, or create a new playlist for it.  Presented as a sheet.
//
// Usage:
//   .sheet(item: $trackForAddToPlaylist) { track in
//       NavidromeAddToPlaylistSheet(
//           track: track,
//           viewModel: viewModel,
//           api: api
//       )
//   }

#if canImport(UIKit)
import SwiftUI

struct NavidromeAddToPlaylistSheet: View {
    let track: Track
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let api: NavidromeAPI

    @Environment(\.dismiss) private var dismiss

    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var isCreating = false
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.playlistsState == .loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading playlists…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    playlistPicker
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel adding to playlist")
                }
            }
            .task {
                // Always refresh the list when the sheet opens.
                await viewModel.loadPlaylists()
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                    .autocorrectionDisabled()
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        isCreating = true
                        await viewModel.createPlaylist(name: name, songIds: [track.id])
                        isCreating = false
                        dismiss()
                    }
                }
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("Enter a name for the new playlist.")
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
        .presentationDetents([.medium, .large])
    }

    private var playlistPicker: some View {
        List {
            // New playlist row at the top
            Button {
                newPlaylistName = ""
                showNewPlaylistAlert = true
            } label: {
                Label("New Playlist…", systemImage: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel("Create new playlist and add song")

            // Existing playlists
            if !viewModel.playlists.isEmpty {
                Section {
                    ForEach(viewModel.playlists, id: \.id) { playlist in
                        Button {
                            Task {
                                isAdding = true
                                await viewModel.addTrackToPlaylist(
                                    playlistId: playlist.id,
                                    trackId: track.id
                                )
                                isAdding = false
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                // uxd.4: no longer blanket-hidden — SubsonicCoverArt
                                // manages its own accessibilityHidden state so the
                                // failed-load retry button stays reachable.
                                SubsonicCoverArt(
                                    api: api,
                                    coverArtID: playlist.coverArt,
                                    size: 80,
                                    width: 40,
                                    height: 40,
                                    cornerRadius: 6
                                )

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

                                Spacer()
                            }
                        }
                        .accessibilityLabel("Add to \(playlist.name)")
                        .accessibilityHint(
                            "\(playlist.songCount) \(playlist.songCount == 1 ? "song" : "songs")"
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .disabled(isAdding || isCreating)
        .overlay {
            if isAdding || isCreating {
                ProgressView()
                    .accessibilityLabel("Adding to playlist")
            }
        }
    }
}

// MARK: - Preview

#Preview("Add to Playlist") {
    let api = NavidromeAPI(
        host: URL(string: "https://demo.navidrome.org")!,
        username: "demo",
        password: "demo"
    )
    let track = Track(
        id: "t1",
        albumId: "al1",
        artistId: "ar1",
        title: "Airbag",
        updatedAt: 0
    )
    return NavidromeAddToPlaylistSheet(
        track: track,
        viewModel: NavidromeLibraryViewModel(api: api),
        api: api
    )
}
#endif // canImport(UIKit)
