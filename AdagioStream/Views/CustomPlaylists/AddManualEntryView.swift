import SwiftUI

struct AddManualEntryView: View {
    let playlistID: UUID
    @EnvironmentObject var playlistManager: CustomPlaylistManager
    @Environment(\.dismiss) private var dismiss

    @State private var streamName = ""
    @State private var streamURLText = ""
    @State private var logoURLText = ""
    @State private var selectedGroupID: UUID?
    @State private var showingNewGroup = false
    @State private var newGroupName = ""

    private var playlist: CustomPlaylist? {
        playlistManager.playlists.first { $0.id == playlistID }
    }

    private var isValid: Bool {
        let trimmedName = streamName.trimmingCharacters(in: .whitespaces)
        let trimmedURL = streamURLText.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty, selectedGroupID != nil else { return false }
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "rtsp", "rtmp", "mms"].contains(scheme) else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Stream Info") {
                    TextField("Stream name", text: $streamName)
                    TextField("Stream URL", text: $streamURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Logo URL (optional)", text: $logoURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let playlist {
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
            .navigationTitle("Add Stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addEntry()
                    }
                    .disabled(!isValid)
                }
            }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        if let group = playlistManager.addGroup(named: name, to: playlistID) {
                            selectedGroupID = group.id
                        }
                    }
                }
            }
            .onAppear {
                selectedGroupID = playlist?.groups.first?.id
            }
        }
    }

    private func addEntry() {
        guard let groupID = selectedGroupID,
              let streamURL = URL(string: streamURLText.trimmingCharacters(in: .whitespaces)) else { return }
        let logoURL = URL(string: logoURLText.trimmingCharacters(in: .whitespaces))
        let entry = CustomPlaylistEntry(
            name: streamName.trimmingCharacters(in: .whitespaces),
            streamURL: streamURL,
            logoURL: logoURL
        )
        playlistManager.addEntry(entry, to: groupID, in: playlistID)
        dismiss()
    }
}
