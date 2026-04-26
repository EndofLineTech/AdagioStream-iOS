import AdagioStreamCore
import SwiftUI

struct AddToPlaylistSheet: View {
    let channel: Channel
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlaylistID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var showingNewGroup = false
    @State private var newGroupName = ""

    private var selectedPlaylist: CustomPlaylist? {
        guard let id = selectedPlaylistID else { return nil }
        return playlistManager.playlists.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    ForEach(playlistManager.playlists) { playlist in
                        Button {
                            selectedPlaylistID = playlist.id
                            selectedGroupID = playlist.groups.first?.id
                        } label: {
                            HStack {
                                Label(playlist.name, systemImage: "music.note.list")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedPlaylistID == playlist.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.accent)
                                }
                            }
                        }
                    }

                    Button {
                        newPlaylistName = ""
                        showingNewPlaylist = true
                    } label: {
                        Label("New Playlist...", systemImage: "plus")
                    }
                }

                if let playlist = selectedPlaylist {
                    Section("Group") {
                        ForEach(playlist.groups) { group in
                            Button {
                                selectedGroupID = group.id
                            } label: {
                                HStack {
                                    Label(group.name, systemImage: "folder")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedGroupID == group.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.accent)
                                    }
                                }
                            }
                        }

                        Button {
                            newGroupName = ""
                            showingNewGroup = true
                        } label: {
                            Label("New Group...", systemImage: "plus")
                        }
                    }
                }
            }
            .navigationTitle("Add to M3U")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let playlistID = selectedPlaylistID, let groupID = selectedGroupID {
                            playlistManager.addChannel(channel, to: groupID, in: playlistID)
                        }
                        dismiss()
                    }
                    .disabled(selectedPlaylistID == nil || selectedGroupID == nil)
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        let playlist = playlistManager.createPlaylist(name: name)
                        selectedPlaylistID = playlist.id
                        selectedGroupID = nil
                    }
                }
            }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let playlistID = selectedPlaylistID {
                        if let group = playlistManager.addGroup(named: name, to: playlistID) {
                            selectedGroupID = group.id
                        }
                    }
                }
            }
        }
    }
}
