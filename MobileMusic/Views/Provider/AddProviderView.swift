import SwiftUI

struct AddProviderView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var providerType = 0 // 0 = M3U, 1 = Xtream Codes

    // M3U fields
    @State private var m3uURL = ""
    @State private var epgURL = ""

    // Xtream Codes fields
    @State private var xcHost = ""
    @State private var xcUsername = ""
    @State private var xcPassword = ""

    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider Details") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $providerType) {
                        Text("M3U Playlist").tag(0)
                        Text("Xtream Codes").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                if providerType == 0 {
                    Section("M3U Settings") {
                        TextField("Playlist URL", text: $m3uURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("EPG URL (optional)", text: $epgURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } else {
                    Section("Xtream Codes Settings") {
                        TextField("Server URL", text: $xcHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Username", text: $xcUsername)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $xcPassword)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Save") { save() }
                            .disabled(!isValid)
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if providerType == 0 {
            return URL(string: m3uURL) != nil
        } else {
            return URL(string: xcHost) != nil && !xcUsername.isEmpty && !xcPassword.isEmpty
        }
    }

    private func save() {
        isSaving = true
        error = nil

        let type: Provider.ProviderType
        if providerType == 0 {
            guard let url = URL(string: m3uURL) else {
                error = "Invalid playlist URL"
                isSaving = false
                return
            }
            let epg = URL(string: epgURL)
            type = .m3u(url: url, epgURL: epg)
        } else {
            guard let host = URL(string: xcHost) else {
                error = "Invalid server URL"
                isSaving = false
                return
            }
            type = .xtreamCodes(host: host, username: xcUsername, password: xcPassword)
        }

        let provider = Provider(name: name, type: type)
        Task {
            await providerManager.addProvider(provider)
            dismiss()
        }
    }
}
