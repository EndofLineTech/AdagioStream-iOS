import SwiftUI
import UIKit

private struct MaskedTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    private static let bullet = "\u{25CF}"

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.textContentType = .init(rawValue: "")
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let masked = String(repeating: Self.bullet, count: text.count)
        if field.text != masked { field.text = masked }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let current = text.wrappedValue
            guard let r = Range(range, in: current) else { return false }
            text.wrappedValue = current.replacingCharacters(in: r, with: string)
            // Update display to bullets and fix cursor position
            let newMasked = String(repeating: MaskedTextField.bullet, count: text.wrappedValue.count)
            textField.text = newMasked
            let cursorOffset = range.location + string.count
            if let pos = textField.position(from: textField.beginningOfDocument, offset: cursorOffset) {
                textField.selectedTextRange = textField.textRange(from: pos, to: pos)
            }
            return false
        }
    }
}

struct AddProviderView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing provider to edit it; leave nil to add a new one.
    var editing: Provider?

    @State private var name = ""
    @State private var providerType = 0 // 0 = M3U, 1 = Xtream Codes

    // M3U fields
    @State private var m3uURL = ""
    @State private var epgURL = ""

    // Xtream Codes fields
    @State private var xcHost = ""
    @State private var xcUsername = ""
    @State private var xcPassword = ""
    @State private var stripStreamIDs = false

    @State private var error: String?
    @State private var isSaving = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Details") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $providerType) {
                        Text("M3U Playlist").tag(0)
                        Text("Xtream Codes").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEditing)
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
                            .textContentType(.init(rawValue: ""))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        MaskedTextField(placeholder: "Password", text: $xcPassword)
                    }

                    Section {
                        Toggle("Strip numeric prefix from channel names", isOn: $stripStreamIDs)
                    } footer: {
                        Text("Enable this if your channel names start with a number and pipe (e.g. \"5204 | Radio: Bruins\"). This strips the prefix so channels display and match correctly.")
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

    private static let allowedSchemes: Set<String> = ["http", "https"]

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if providerType == 0 {
            guard let url = URL(string: m3uURL),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else { return false }
            return true
        } else {
            guard let url = URL(string: xcHost),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else { return false }
            return !xcUsername.isEmpty && !xcPassword.isEmpty
        }
    }

    private func populateFromEditing() {
        guard let provider = editing else { return }
        name = provider.name
        switch provider.type {
        case .m3u(let url, let epg):
            providerType = 0
            m3uURL = url.absoluteString
            epgURL = epg?.absoluteString ?? ""
        case .xtreamCodes(let host, let username, let password):
            providerType = 1
            xcHost = host.absoluteString
            xcUsername = username
            xcPassword = password
        }
        stripStreamIDs = provider.stripStreamIDs
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
            let epg: URL? = {
                guard let u = URL(string: epgURL),
                      let s = u.scheme?.lowercased(),
                      Self.allowedSchemes.contains(s) else { return nil }
                return u
            }()
            type = .m3u(url: url, epgURL: epg)
        } else {
            guard let host = URL(string: xcHost) else {
                error = "Invalid server URL"
                isSaving = false
                return
            }
            type = .xtreamCodes(host: host, username: xcUsername, password: xcPassword)
        }

        if let existing = editing {
            let updated = Provider(id: existing.id, name: name, type: type, isEnabled: existing.isEnabled, stripStreamIDs: stripStreamIDs)
            Task {
                await providerManager.updateProvider(updated)
                await providerManager.loadChannels()
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
