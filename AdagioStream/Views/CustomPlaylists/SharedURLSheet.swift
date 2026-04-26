import AdagioStreamCore
import SwiftUI

struct SharedURLEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
}

struct SharedURLSheet: View {
    let entry: SharedURLEntry
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @Environment(\.dismiss) private var dismiss

    @State private var entryName: String
    @State private var selectedPlaylistID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var showingNewGroup = false
    @State private var newGroupName = ""

    init(entry: SharedURLEntry) {
        self.entry = entry
        _entryName = State(initialValue: entry.name)
    }

    private var selectedPlaylist: CustomPlaylist? {
        guard let id = selectedPlaylistID else { return nil }
        return playlistManager.playlists.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Stream") {
                    TextField("Name", text: $entryName)
                    HStack {
                        Text("URL")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

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
            .navigationTitle("Add Shared URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addEntry()
                    }
                    .disabled(selectedPlaylistID == nil || selectedGroupID == nil || entryName.trimmingCharacters(in: .whitespaces).isEmpty)
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
            .onAppear {
                selectedPlaylistID = playlistManager.playlists.first?.id
                selectedGroupID = playlistManager.playlists.first?.groups.first?.id
            }
        }
    }

    private func addEntry() {
        guard let playlistID = selectedPlaylistID, let groupID = selectedGroupID else { return }
        let name = entryName.trimmingCharacters(in: .whitespaces)
        let playlistEntry = CustomPlaylistEntry(
            name: name.isEmpty ? entry.url.absoluteString : name,
            streamURL: entry.url
        )
        playlistManager.addEntry(playlistEntry, to: groupID, in: playlistID)
        dismiss()
    }
}
