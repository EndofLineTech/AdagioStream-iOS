import AdagioStreamCore
import SwiftUI

struct CustomPlaylistListView: View {
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @State private var showingCreateAlert = false
    @State private var newPlaylistName = ""
    @State private var renamingPlaylist: CustomPlaylist?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if playlistManager.playlists.isEmpty {
                    EmptyStateView(
                        title: "No Playlists",
                        systemImage: "music.note.list",
                        description: "Tap + to create a custom playlist."
                    )
                } else {
                    List {
                        ForEach(playlistManager.playlists) { playlist in
                            NavigationLink(value: playlist.id) {
                                PlaylistRow(playlist: playlist)
                            }
                            .contextMenu {
                                    Button {
                                        renameText = playlist.name
                                        renamingPlaylist = playlist
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        playlistManager.deletePlaylist(playlist.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                playlistManager.deletePlaylist(playlistManager.playlists[index].id)
                            }
                        }
                        .onMove { playlistManager.movePlaylists(from: $0, to: $1) }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { playlistID in
                CustomPlaylistDetailView(playlistID: playlistID)
            }
            .navigationTitle("My M3Us")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showingCreateAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showingCreateAlert) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        _ = playlistManager.createPlaylist(name: name)
                    }
                }
            }
            .alert("Rename Playlist", isPresented: Binding(
                get: { renamingPlaylist != nil },
                set: { if !$0 { renamingPlaylist = nil } }
            )) {
                TextField("Playlist name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingPlaylist = nil }
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let playlist = renamingPlaylist {
                        playlistManager.renamePlaylist(playlist.id, to: name)
                    }
                    renamingPlaylist = nil
                }
            }
        }
    }
}

private struct PlaylistRow: View {
    let playlist: CustomPlaylist

    private var entryCount: Int {
        playlist.groups.reduce(0) { $0 + $1.entries.count }
    }

    var body: some View {
        HStack {
            Image(systemName: "music.note.list")
                .foregroundStyle(.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                Text("\(playlist.groups.count) groups, \(entryCount) channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
