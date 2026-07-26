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

    // beads_mobilemusic-uxb.3: inline field-level validation captions —
    // decision logic lives in ProviderFormValidation.validateManualEntry so
    // it's covered by the same truth-table tests as the provider forms.
    private enum ValidationField: Hashable { case name, url }
    @State private var hasSubmitted = false
    @State private var touchedFields: Set<ValidationField> = []

    private func markTouched(_ field: ValidationField, if value: String) {
        if !value.isEmpty { touchedFields.insert(field) }
    }

    @ViewBuilder
    private func caption(_ message: String?, field: ValidationField) -> some View {
        if let message, hasSubmitted || touchedFields.contains(field) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var playlist: CustomPlaylist? {
        playlistManager.playlists.first { $0.id == playlistID }
    }

    private var fieldErrors: ProviderFormValidation.ManualEntryResult {
        ProviderFormValidation.validateManualEntry(
            name: streamName,
            url: streamURLText,
            hasGroup: selectedGroupID != nil
        )
    }

    private var isValid: Bool { fieldErrors.isValid }

    var body: some View {
        NavigationStack {
            Form {
                Section("Stream Info") {
                    TextField("Stream name", text: $streamName)
                        .onChange(of: streamName) { _, newValue in markTouched(.name, if: newValue) }
                    caption(fieldErrors.name, field: .name)
                    TextField("Stream URL", text: $streamURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: streamURLText) { _, newValue in markTouched(.url, if: newValue) }
                    caption(fieldErrors.url, field: .url)
                    TextField("Logo URL (optional)", text: $logoURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let playlist {
                    Section {
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
                    } header: {
                        Text("Group")
                    } footer: {
                        // No typed field to "touch" for a tap-to-select row —
                        // gated by submit-attempt only, unlike the text fields above.
                        if let message = fieldErrors.group, hasSubmitted {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
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
        hasSubmitted = true
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
