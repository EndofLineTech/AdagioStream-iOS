import SwiftUI

struct CustomPlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var showingAddGroup = false
    @State private var newGroupName = ""
    @State private var showingAddEntry = false
    @State private var shareFileURL: URL?

    private var playlist: CustomPlaylist? {
        playlistManager.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                if playlist.groups.isEmpty {
                    EmptyStateView(
                        title: "No Groups",
                        systemImage: "folder",
                        description: "Tap + to add a group to this playlist."
                    )
                } else {
                    List {
                        ForEach(playlist.groups) { group in
                            Section(isExpanded: .constant(true)) {
                                ForEach(group.entries) { entry in
                                    CustomPlaylistEntryRowView(entry: entry) {
                                        playEntry(entry, in: playlist)
                                    }
                                }
                                .onDelete { offsets in
                                    deleteEntries(at: offsets, in: group)
                                }
                                .onMove { source, destination in
                                    playlistManager.moveEntries(from: source, to: destination, in: group.id, in: playlistID)
                                }
                            } header: {
                                GroupHeader(group: group, playlistID: playlistID)
                            }
                        }
                        .onDelete { offsets in
                            deleteGroups(at: offsets)
                        }
                        .onMove { source, destination in
                            playlistManager.moveGroups(from: source, to: destination, in: playlistID)
                        }
                    }
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if let playlist {
                        ShareLink(item: M3UExporter.export(playlist), preview: SharePreview(playlist.name, image: Image(systemName: "music.note.list")))
                    }
                    Button {
                        showingAddEntry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        newGroupName = ""
                        showingAddGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $showingAddEntry) {
            AddManualEntryView(playlistID: playlistID)
        }
        .alert("New Group", isPresented: $showingAddGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { }
            Button("Add") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    playlistManager.addGroup(named: name, to: playlistID)
                }
            }
        }
    }

    private func playEntry(_ entry: CustomPlaylistEntry, in playlist: CustomPlaylist) {
        let allEntries = playlist.groups.flatMap(\.entries)
        let channels = allEntries.map { $0.asChannel }
        audioPlayer.channels = channels
        audioPlayer.play(channel: entry.asChannel)
    }

    private func deleteEntries(at offsets: IndexSet, in group: CustomPlaylistGroup) {
        for index in offsets {
            playlistManager.removeEntry(group.entries[index].id, from: group.id, in: playlistID)
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        guard let playlist else { return }
        for index in offsets {
            playlistManager.deleteGroup(playlist.groups[index].id, from: playlistID)
        }
    }
}

private struct GroupHeader: View {
    let group: CustomPlaylistGroup
    let playlistID: UUID
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @State private var showingRename = false
    @State private var renameText = ""

    var body: some View {
        Text(group.name)
            .contextMenu {
                Button {
                    renameText = group.name
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    playlistManager.deleteGroup(group.id, from: playlistID)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .alert("Rename Group", isPresented: $showingRename) {
                TextField("Group name", text: $renameText)
                Button("Cancel", role: .cancel) { }
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        playlistManager.renameGroup(group.id, to: name, in: playlistID)
                    }
                }
            }
    }
}
