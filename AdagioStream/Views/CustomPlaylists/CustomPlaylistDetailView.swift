import SwiftUI

struct CustomPlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var showingAddGroup = false
    @State private var newGroupName = ""
    @State private var showingAddEntry = false
    @State private var groupToDelete: CustomPlaylistGroup?

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
                                GroupHeader(group: group, playlistID: playlistID) {
                                    groupToDelete = group
                                }
                            }
                        }
                        .onDelete { offsets in
                            // `offsets.first` only ever has one element: List's
                            // built-in swipe-to-delete is single-row, and there
                            // is no multi-select UI for groups (unlike EditButton's
                            // reorder mode). Not a bug — just narrower than IndexSet
                            // implies (beads_mobilemusic-uxc kickback nit).
                            if let index = offsets.first {
                                groupToDelete = playlist.groups[index]
                            }
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
                    if let playlist, let exportURL = try? M3UExporter.exportToFile(playlist) {
                        ShareLink(item: exportURL, preview: SharePreview(playlist.name, image: Image(systemName: "music.note.list")))
                    }
                    Button {
                        showingAddEntry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add entry")
                    Button {
                        newGroupName = ""
                        showingAddGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("Add group")
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
                    _ = playlistManager.addGroup(named: name, to: playlistID)
                }
            }
        }
        // uxc.6: group deletion (context menu + swipe) had no confirmation —
        // mirrors CustomPlaylistListView's playlist-delete confirmationDialog.
        .confirmationDialog(
            "Delete Group",
            isPresented: Binding(
                get: { groupToDelete != nil },
                set: { if !$0 { groupToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let group = groupToDelete {
                    playlistManager.deleteGroup(group.id, from: playlistID)
                }
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) { groupToDelete = nil }
        } message: {
            if let group = groupToDelete {
                Text("Are you sure you want to delete \"\(group.name)\"? Its channels will be removed.")
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
}

private struct GroupHeader: View {
    let group: CustomPlaylistGroup
    let playlistID: UUID
    /// uxc.6: requests confirmation from the parent instead of deleting
    /// immediately — the parent owns the shared confirmationDialog.
    let onDeleteRequest: () -> Void
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
                    onDeleteRequest()
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
