import SwiftUI

struct CustomPlaylistListView: View {
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @EnvironmentObject var providerManager: ProviderManager
    @State private var showingCreateAlert = false
    @State private var newPlaylistName = ""
    @State private var renamingPlaylist: CustomPlaylist?
    @State private var renameText = ""
    @State private var showingAddM3U = false
    @State private var m3uToEdit: Provider?
    @State private var m3uToDelete: Provider?

    private var m3uProviders: [Provider] {
        providerManager.providers.filter {
            if case .m3u = $0.type { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if playlistManager.playlists.isEmpty && m3uProviders.isEmpty {
                    EmptyStateView(
                        title: "No Playlists",
                        systemImage: "music.note.list",
                        description: "Tap + to create a custom playlist or add an M3U."
                    )
                } else {
                    List {
                        if !m3uProviders.isEmpty {
                            Section("M3U Accounts") {
                                ForEach(m3uProviders) { provider in
                                    M3URow(provider: provider)
                                        .swipeActions(edge: .leading) {
                                            Button { m3uToEdit = provider } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                            .tint(.blue)
                                        }
                                        .contextMenu {
                                            Button { m3uToEdit = provider } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                            Button(role: .destructive) { m3uToDelete = provider } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                                .onDelete { offsets in
                                    if let index = offsets.first {
                                        m3uToDelete = m3uProviders[index]
                                    }
                                }
                            }
                        }

                        if !playlistManager.playlists.isEmpty {
                            Section("Playlists") {
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
                }
            }
            .navigationDestination(for: UUID.self) { playlistID in
                CustomPlaylistDetailView(playlistID: playlistID)
            }
            .navigationTitle("Custom M3Us")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newPlaylistName = ""
                            showingCreateAlert = true
                        } label: {
                            Label("New Playlist", systemImage: "music.note.list")
                        }
                        Button {
                            showingAddM3U = true
                        } label: {
                            Label("Add M3U", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add playlist or M3U")
                }
            }
            .sheet(isPresented: $showingAddM3U) {
                AddProviderView(lockedToM3U: true)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $m3uToEdit) { provider in
                AddProviderView(editing: provider)
                    .presentationDetents([.medium, .large])
            }
            .alert("Delete M3U", isPresented: Binding(
                get: { m3uToDelete != nil },
                set: { if !$0 { m3uToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let provider = m3uToDelete {
                        Task {
                            await providerManager.deleteProvider(provider)
                            await providerManager.loadChannels()
                        }
                    }
                    m3uToDelete = nil
                }
                Button("Cancel", role: .cancel) { m3uToDelete = nil }
            } message: {
                if let provider = m3uToDelete {
                    Text("Are you sure you want to delete \"\(provider.name)\"? Its channels will be removed.")
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

private struct M3URow: View {
    let provider: Provider

    var body: some View {
        HStack {
            Image(systemName: "link")
                .foregroundStyle(.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body)
                Text("M3U Playlist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
