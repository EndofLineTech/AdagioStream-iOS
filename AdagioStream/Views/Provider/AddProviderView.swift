import SwiftUI

struct AddProviderView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing provider to edit it; leave nil to add a new one.
    var editing: Provider?

    /// When true, adding is locked to M3U: the type picker is hidden and only the
    /// M3U form shows. Used by the "Custom M3Us" tab entry point. Ignored when editing.
    var lockedToM3U = false

    @State private var name = ""
    @State private var formProviderType: FormProviderType

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

    // Audiobookshelf fields
    @State private var absHost = ""
    @State private var absUsername = ""
    @State private var absPassword = ""

    // Audiobookshelf discovery (URL-first flow, bug 1e4). `.task(id: absHost)`
    // drives it; `absDiscoveryToken` is bumped by "Retry" to re-run without an
    // edit. `absDiscoveryPhase` is the single source of truth for the UI.
    @State private var absDiscoveryPhase: ABSDiscoveryPhase = .idle
    @State private var absDiscoveryToken = 0
    @State private var isSigningIn = false

    enum ABSDiscoveryPhase: Equatable {
        case idle
        case checking
        case done(AudiobookshelfOIDC.Discovery)
        case failed(String)
    }

    /// Convenience: the successful discovery, if any.
    private var absDiscovery: AudiobookshelfOIDC.Discovery? {
        if case .done(let d) = absDiscoveryPhase { return d }
        return nil
    }

    /// Show username/password when the server advertises local auth, when
    /// discovery failed, or when it hasn't run yet (empty/http URL) — so the
    /// user is never locked out of the password path. Floor: if SSO is NOT the
    /// offered path (e.g. authMethods ["ldap"]), still show password so an
    /// unrecognized auth method can't hide every credential field.
    private var absShowsPasswordFields: Bool {
        switch absDiscoveryPhase {
        case .done(let d): return d.supportsLocal || !d.supportsOpenID
        case .idle, .failed: return true
        case .checking: return false
        }
    }
    /// Retains the ASWebAuthenticationSession driver for the flow's lifetime.
    @State private var oidcSession = AudiobookshelfOIDCSession()

    @State private var error: String?
    @State private var isSaving = false

    init(editing: Provider? = nil, lockedToM3U: Bool = false) {
        self.editing = editing
        self.lockedToM3U = lockedToM3U
        // Derive the initial form type on first paint so editing shows the right
        // form immediately (no one-frame Xtream flash). When adding a new provider,
        // default the picker to Xtream Codes since M3U is no longer a picker option
        // (it's added from the Custom M3Us tab).
        let initialType: FormProviderType
        if let editing {
            switch editing.type {
            case .m3u: initialType = .m3u
            case .xtreamCodes: initialType = .xtreamCodes
            case .subsonic: initialType = .subsonic
            case .audiobookshelf: initialType = .audiobookshelf
            }
        } else {
            initialType = lockedToM3U ? .m3u : .xtreamCodes
        }
        _formProviderType = State(initialValue: initialType)
    }

    private var isEditing: Bool { editing != nil }

    /// M3U is excluded from the picker: new M3Us are added from the Custom M3Us tab.
    private var pickerTypes: [FormProviderType] {
        FormProviderType.allCases.filter { $0 != .m3u }
    }

    /// Hide the type picker when there's nothing to choose: locked to M3U, or
    /// editing an M3U provider (whose type can't change and isn't a picker option).
    private var hidePicker: Bool {
        lockedToM3U || (isEditing && formProviderType == .m3u)
    }

    // MARK: - Typed provider-form enum (replaces fragile Int picker)

    private enum FormProviderType: CaseIterable {
        case m3u
        case xtreamCodes
        case subsonic
        case audiobookshelf

        var label: String {
            switch self {
            case .m3u: return "M3U"
            case .xtreamCodes: return "Xtream Codes"
            case .subsonic: return "Navidrome"
            case .audiobookshelf: return "Audiobookshelf"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Details") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Account name")
                    if !hidePicker {
                        Picker("Type", selection: $formProviderType) {
                            ForEach(pickerTypes, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isEditing)
                        .accessibilityLabel("Provider type")
                    }
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

                    if isXtreamCodesHTTP {
                        Section {
                            Label(
                                "This connection is not encrypted. Your credentials and library info could be visible on the network.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                            .font(.footnote)
                        }
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

                case .audiobookshelf:
                    // URL-first: only the server URL shows until discovery reveals
                    // which auth methods the server offers. Discovery runs off the
                    // committed URL via `.task(id:)` — SwiftUI cancels/restarts it
                    // on every edit, so there is no fragile self-referential
                    // "did the host change while I slept" re-check (bug 1e4).
                    Section {
                        TextField("Server URL", text: $absHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Audiobookshelf server URL")
                            .task(id: AnyHashable([absHost, String(absDiscoveryToken)])) { await discoverABS() }
                    } header: {
                        Text("Audiobookshelf Settings")
                    } footer: {
                        Text("Include http:// or https://, e.g. https://abs.example.com. Requires server 2.26.0 or newer.")
                    }

                    // Visible discovery state (replaces the old silent `try?`).
                    if case .checking = absDiscoveryPhase {
                        Section {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking sign-in options…")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Checking sign-in options")
                        }
                    }
                    if case .failed(let message) = absDiscoveryPhase {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                            Button("Retry") { absDiscoveryToken &+= 1 }
                                .accessibilityLabel("Retry checking sign-in options")
                        } footer: {
                            Text("Couldn't reach the server to check sign-in options. Enter your username and password below, or fix the URL and retry.")
                        }
                    }

                    // Username/password: shown when the server offers local auth,
                    // OR whenever discovery failed / hasn't run (so the user is
                    // never locked out and the http password path still works).
                    if absShowsPasswordFields {
                        Section {
                            TextField("Username", text: $absUsername)
                                .textContentType(.init(rawValue: ""))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .accessibilityLabel("Audiobookshelf username")
                            MaskedTextField(placeholder: "Password", text: $absPassword)
                                .accessibilityLabel("Audiobookshelf password")
                        } header: {
                            Text("Sign in with username & password")
                        }
                    }

                    if !isEditing, let discovery = absDiscovery, discovery.supportsOpenID {
                        Section {
                            Button {
                                signInWithSSO()
                            } label: {
                                HStack {
                                    if isSigningIn {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "person.badge.key")
                                    }
                                    Text(discovery.buttonText)
                                }
                            }
                            .disabled(isSigningIn || name.isEmpty || absSSOHost == nil)
                            .accessibilityLabel("Sign in with single sign-on")
                        } footer: {
                            Text("Enter a name above, then sign in through your identity provider. No password is stored.")
                        }

                        Section {
                            DisclosureGroup("SSO server requirements") {
                                Text(Self.ssoSetupHelp)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("SSO server requirements")
                        }
                    }

                    if isAudiobookshelfHTTP {
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
            .navigationTitle(isEditing ? "Edit Account" : (lockedToM3U ? "Add M3U" : "Add Account"))
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

    private var isXtreamCodesHTTP: Bool {
        guard formProviderType == .xtreamCodes,
              let url = URL(string: xcHost),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
    }

    private var isAudiobookshelfHTTP: Bool {
        guard formProviderType == .audiobookshelf,
              let url = URL(string: absHost),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
    }

    /// Valid HTTPS ABS host, or nil. SSO carries code/code_verifier/tokens, so
    /// the discovery + sign-in path is https-only (the password path still
    /// accepts http via `allowedSchemes`, unchanged).
    private var absSSOHost: URL? {
        guard let url = URL(string: absHost),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Server-side setup the app cannot do itself, surfaced in the SSO section
    /// (wv4.4). Condensed to the essentials (3h6.7) — full detail in
    /// docs/design/audiobookshelf-sso-setup.md for server admins.
    static let ssoSetupHelp = """
    Your Audiobookshelf admin needs to allow-list adagiostream://oauth as a mobile redirect URI, and your identity provider needs the server's mobile-redirect URI allow-listed too.

    • Enter the server URL including any base path (e.g. https://host/audiobookshelf).
    • Requires a trusted certificate and Audiobookshelf 2.26.0+.
    """

    // MARK: - Audiobookshelf OpenID / SSO (wv4.3)

    /// URL-first `GET /status` discovery, driven by `.task(id: absHost)`.
    ///
    /// Runs on the main actor; SwiftUI cancels and restarts it whenever `absHost`
    /// (or the Retry token) changes, so there is no manual "did the host change
    /// while I slept" re-check — the previous root cause (bug 1e4), where that
    /// self-referential guard non-deterministically dropped the result and the
    /// silent `try?` hid the failure, giving the user no SSO button and no error.
    ///
    /// Failures are now VISIBLE: `.failed` surfaces an inline message + Retry and
    /// still shows the password fields, so the user is never locked out.
    @MainActor
    private func discoverABS() async {
        guard formProviderType == .audiobookshelf, !isEditing else {
            absDiscoveryPhase = .idle
            return
        }
        // No https URL yet → idle (password path still available for http, and
        // SSO is https-only). Empty/partial input shouldn't show errors.
        guard let host = absSSOHost else {
            absDiscoveryPhase = .idle
            return
        }
        // Debounce: a cancellable sleep. If the user keeps typing, SwiftUI
        // cancels this task and starts a fresh one — the sleep throws and we bail.
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return // cancelled — a newer task owns discovery
        }
        absDiscoveryPhase = .checking
        do {
            let discovery = try await AudiobookshelfOIDC.discover(host: host)
            guard !Task.isCancelled else { return }
            absDiscoveryPhase = .done(discovery)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugLogger.shared.log(
                "ABS discovery failed for \(host.absoluteString): \(message)",
                category: .general
            )
            absDiscoveryPhase = .failed(message)
        }
    }

    /// Runs the OpenID flow, seeds the returned tokens into the Keychain, then
    /// creates a token-only ABS provider (empty username/password). The provider
    /// validation reuses the seeded tokens (no password login).
    private func signInWithSSO() {
        guard let host = absSSOHost, !name.isEmpty else { return }
        error = nil
        isSigningIn = true
        Task {
            do {
                let tokens = try await oidcSession.signIn(host: host)
                let provider = Provider(
                    name: name,
                    type: .audiobookshelf(host: host, username: "", password: ""),
                    stripStreamIDs: false
                )
                // Seed BEFORE addProvider so its validation uses these tokens.
                let auth = AudiobookshelfAuth(
                    host: host, username: "", password: "",
                    providerID: provider.id.uuidString
                )
                await auth.seedTokens(tokens)
                await providerManager.addProvider(provider)
                await MainActor.run {
                    isSigningIn = false
                    if let loadError = providerManager.error {
                        error = loadError
                    } else {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isSigningIn = false
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
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
        case .audiobookshelf:
            guard let url = URL(string: absHost),
                  let scheme = url.scheme?.lowercased(),
                  Self.allowedSchemes.contains(scheme) else { return false }
            return !absUsername.isEmpty && !absPassword.isEmpty
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
        case .audiobookshelf(let host, let username, let password):
            formProviderType = .audiobookshelf
            absHost = host.absoluteString
            absUsername = username
            absPassword = password
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

        case .audiobookshelf:
            guard let host = URL(string: absHost) else {
                error = "Invalid server URL"
                isSaving = false
                return
            }
            type = .audiobookshelf(host: host, username: absUsername, password: absPassword)
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
