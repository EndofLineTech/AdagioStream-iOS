import SwiftUI

struct AddProviderView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing provider to edit it; leave nil to add a new one.
    var editing: Provider?

    @State private var name = ""
    @State private var formProviderType: FormProviderType = .m3u

    // M3U fields
    @State private var m3uURL = ""
    @State private var epgURL = ""

    // Xtream Codes fields
    @State private var xcHost = ""
    @State private var xcUsername = ""
    @State private var xcPassword = ""
    @State private var stripStreamIDs = false

    // Subsonic fields
    @State private var subsonicHost = ""
    @State private var subsonicUsername = ""
    @State private var subsonicPassword = ""

    @State private var error: String?
    @State private var isSaving = false

    private var isEditing: Bool { editing != nil }

    // MARK: - Typed provider-form enum (replaces fragile Int picker)

    private enum FormProviderType: CaseIterable {
        case m3u
        case xtreamCodes
        case subsonic

        var label: String {
            switch self {
            case .m3u: return "M3U"
            case .xtreamCodes: return "Xtream Codes"
            case .subsonic: return "Navidrome"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Details") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Account name")
                    Picker("Type", selection: $formProviderType) {
                        ForEach(FormProviderType.allCases, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEditing)
                    .accessibilityLabel("Provider type")
                }

                switch formProviderType {
                case .m3u:
                    Section("M3U Settings") {
                        TextField("Playlist URL", text: $m3uURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Playlist URL")
                        TextField("EPG URL (optional)", text: $epgURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("EPG URL, optional")
                    }

                case .xtreamCodes:
                    Section("Xtream Codes Settings") {
                        TextField("Server URL", text: $xcHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Xtream Codes server URL")
                        TextField("Username", text: $xcUsername)
                            .textContentType(.init(rawValue: ""))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Xtream Codes username")
                        MaskedTextField(placeholder: "Password", text: $xcPassword)
                            .accessibilityLabel("Xtream Codes password")
                    }

                    Section {
                        Toggle("Strip numeric prefix from channel names", isOn: $stripStreamIDs)
                    } footer: {
                        Text("Enable this if your channel names start with a number and pipe (e.g. \"5204 | Radio: Bruins\"). This strips the prefix so channels display and match correctly.")
                    }

                case .subsonic:
                    Section {
                        TextField("Server URL", text: $subsonicHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Navidrome server URL")
                        TextField("Username", text: $subsonicUsername)
                            .textContentType(.init(rawValue: ""))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Navidrome username")
                        MaskedTextField(placeholder: "Password", text: $subsonicPassword)
                            .accessibilityLabel("Navidrome password")
                    } header: {
                        Text("Navidrome / Subsonic Settings")
                    } footer: {
                        Text("Include http:// or https://, e.g. http://nas.local:4533")
                    }

                    if isSubsonicHTTP {
                        Section {
                            Label(
                                "This connection is not encrypted. Your credentials and library info could be visible on the network.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "Add Account")
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
            .onAppear { populateFromEditing() }
        }
    }

    // MARK: - Validation

    private static let allowedSchemes: Set<String> = ["http", "https"]

    private var isSubsonicHTTP: Bool {
        guard formProviderType == .subsonic,
              let url = URL(string: subsonicHost),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
    }

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        switch formProviderType {
        case .m3u:
            guard let url = URL(string: m3uURL),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else { return false }
            return true
        case .xtreamCodes:
            guard let url = URL(string: xcHost),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else { return false }
            return !xcUsername.isEmpty && !xcPassword.isEmpty
        case .subsonic:
            guard let url = URL(string: subsonicHost),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else { return false }
            return !subsonicUsername.isEmpty && !subsonicPassword.isEmpty
        }
    }

    // MARK: - Populate from editing

    private func populateFromEditing() {
        guard let provider = editing else { return }
        name = provider.name
        switch provider.type {
        case .m3u(let url, let epg):
            formProviderType = .m3u
            m3uURL = url.absoluteString
            epgURL = epg?.absoluteString ?? ""
        case .xtreamCodes(let host, let username, let password):
            formProviderType = .xtreamCodes
            xcHost = host.absoluteString
            xcUsername = username
            xcPassword = password
        case .subsonic(let host, let username, let password):
            formProviderType = .subsonic
            subsonicHost = host.absoluteString
            subsonicUsername = username
            subsonicPassword = password
        }
        stripStreamIDs = provider.stripStreamIDs
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        error = nil

        let type: Provider.ProviderType
        switch formProviderType {
        case .m3u:
            guard let url = URL(string: m3uURL) else {
                error = "Invalid playlist URL"
                isSaving = false
                return
            }
            let epg: URL? = {
                guard let u = URL(string: epgURL),
                      let s = u.scheme?.lowercased(),
                      Self.allowedSchemes.contains(s) else { return nil }
                return u
            }()
            type = .m3u(url: url, epgURL: epg)

        case .xtreamCodes:
            guard let host = URL(string: xcHost) else {
                error = "Invalid server URL"
                isSaving = false
                return
            }
            type = .xtreamCodes(host: host, username: xcUsername, password: xcPassword)

        case .subsonic:
            guard let host = URL(string: subsonicHost) else {
                error = "Invalid server URL"
                isSaving = false
                return
            }
            type = .subsonic(host: host, username: subsonicUsername, password: subsonicPassword)
        }

        if let existing = editing {
            let updated = Provider(
                id: existing.id,
                name: name,
                type: type,
                isEnabled: existing.isEnabled,
                stripStreamIDs: stripStreamIDs
            )
            Task {
                await providerManager.updateProvider(updated)
                if let loadError = providerManager.error {
                    error = loadError
                    isSaving = false
                } else {
                    dismiss()
                }
            }
        } else {
            let provider = Provider(name: name, type: type, stripStreamIDs: stripStreamIDs)
            Task {
                await providerManager.addProvider(provider)
                if let loadError = providerManager.error {
                    error = loadError
                    isSaving = false
                } else {
                    dismiss()
                }
            }
        }
    }
}
