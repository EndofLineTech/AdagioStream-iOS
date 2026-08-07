import SwiftUI

struct WelcomeSetupView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var step: SetupStep = .welcome
    @State private var connectionType: SetupConnectionType = .m3u

    // Shared fields
    @State private var name = ""

    // M3U fields
    @State private var m3uURL = ""
    @State private var epgURL = ""

    // Xtream Codes fields
    @State private var xcHost = ""
    @State private var xcUsername = ""
    @State private var xcPassword = ""

    // Subsonic / Navidrome fields
    @State private var subsonicHost = ""
    @State private var subsonicUsername = ""
    @State private var subsonicPassword = ""

    // Audiobookshelf fields
    @State private var absHost = ""
    @State private var absUsername = ""
    @State private var absPassword = ""

    @State private var error: String?
    @State private var isSaving = false

    var onComplete: () -> Void

    @State private var newGroupNames: [String] = []

    private enum SetupStep {
        case welcome
        case connectionType
        case credentials
        case groupSelection
    }

    private enum SetupConnectionType {
        case m3u
        case xtreamCodes
        case subsonic
        case audiobookshelf
    }

    // beads_mobilemusic-uxb.3: inline field-level validation captions, shared
    // decision logic with AddProviderView via ProviderFormValidation. See that
    // view for why `touchedFields` uses "ever had content" instead of
    // FocusState (MaskedTextField doesn't expose its internal focus state).
    private enum ValidationField: Hashable { case name, host, username, password }
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

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                stepContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .animation(.easeInOut(duration: 0.3), value: step)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    leadingButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    trailingButton
                }
            }
            .onChange(of: connectionType) { _, _ in
                // beads_mobilemusic-uxb kickback finding 4: same fix as
                // AddProviderView — every connection type shares the same
                // name/host/username/password ValidationField cases, so
                // switching types (e.g. going back and picking a different
                // card) must not carry over "touched" state from the type
                // just left.
                touchedFields = []
                error = nil
            }
        }
    }

    // MARK: - Toolbar Buttons

    @ViewBuilder
    private var leadingButton: some View {
        switch step {
        case .welcome:
            EmptyView()
        case .connectionType:
            Button {
                withAnimation { step = .welcome }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Back")
        case .credentials:
            Button {
                error = nil
                withAnimation { step = .connectionType }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Back")
        case .groupSelection:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch step {
        case .welcome:
            if hasExistingProviders {
                Button("Skip") {
                    Task {
                        await settingsViewModel.completeSetup()
                        onComplete()
                    }
                }
            }
        case .connectionType:
            EmptyView()
        case .credentials:
            EmptyView()
        case .groupSelection:
            EmptyView()
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            welcomeView
        case .connectionType:
            connectionTypeView
        case .credentials:
            credentialsView
        case .groupSelection:
            groupSelectionView
        }
    }

    // MARK: - Welcome

    private var hasExistingProviders: Bool {
        !providerManager.providers.isEmpty
    }

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "radio")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("Welcome to Adagio Stream")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            if hasExistingProviders {
                let count = providerManager.providers.count
                Text("You already have \(count) account\(count == 1 ? "" : "s") configured. You can add a new account or skip this setup.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Stream your favorite audio channels from M3U playlists, Xtream Codes providers, your Navidrome music server, or your Audiobookshelf library.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 16) {
                Button {
                    withAnimation { step = .connectionType }
                } label: {
                    Text(hasExistingProviders ? "Add New Account" : "Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                if !hasExistingProviders {
                    Button("Skip Setup") {
                        Task {
                            await settingsViewModel.completeSetup()
                            onComplete()
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Connection Type

    private var connectionTypeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Choose Your Source")
                .font(.title.bold())

            Text("What type of connection will you be using?")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 16) {
                connectionCard(
                    title: "M3U Playlist",
                    description: "Connect using a playlist URL",
                    icon: "music.note.list"
                ) {
                    connectionType = .m3u
                    withAnimation { step = .credentials }
                }

                connectionCard(
                    title: "Xtream Codes",
                    description: "Connect with server URL, username, and password",
                    icon: "server.rack"
                ) {
                    connectionType = .xtreamCodes
                    withAnimation { step = .credentials }
                }

                connectionCard(
                    title: "Navidrome",
                    description: "Connect to a Navidrome or Subsonic music server",
                    icon: "music.note"
                ) {
                    connectionType = .subsonic
                    withAnimation { step = .credentials }
                }

                connectionCard(
                    title: "Audiobookshelf",
                    description: "Connect to an Audiobookshelf server",
                    icon: "books.vertical"
                ) {
                    connectionType = .audiobookshelf
                    withAnimation { step = .credentials }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    private func connectionCard(title: String, description: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 44)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.forward")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Credentials

    private var credentialsViewTitle: String {
        switch connectionType {
        case .m3u: return "M3U Playlist"
        case .xtreamCodes: return "Xtream Codes"
        case .subsonic: return "Navidrome"
        case .audiobookshelf: return "Audiobookshelf"
        }
    }

    private var credentialsView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(credentialsViewTitle)
                    .font(.title.bold())
                Text("Enter your connection details")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Form {
                Section("Account Name") {
                    TextField("My Provider", text: $name)
                        .onChange(of: name) { _, newValue in markTouched(.name, if: newValue) }
                    caption(fieldErrors.name, field: .name)
                }

                switch connectionType {
                case .m3u:
                    Section("Playlist Settings") {
                        TextField("Playlist URL", text: $m3uURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Playlist URL")
                            .onChange(of: m3uURL) { _, newValue in markTouched(.host, if: newValue) }
                        caption(fieldErrors.host, field: .host)
                        TextField("EPG URL (optional)", text: $epgURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("EPG URL, optional")
                    }

                case .xtreamCodes:
                    Section("Server Settings") {
                        TextField("Server URL", text: $xcHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Xtream Codes server URL")
                            .onChange(of: xcHost) { _, newValue in markTouched(.host, if: newValue) }
                        caption(fieldErrors.host, field: .host)
                        TextField("Username", text: $xcUsername)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Xtream Codes username")
                            .onChange(of: xcUsername) { _, newValue in markTouched(.username, if: newValue) }
                        caption(fieldErrors.username, field: .username)
                        MaskedTextField(placeholder: "Password", text: $xcPassword, accessibilityLabel: "Xtream Codes password")
                            .onChange(of: xcPassword) { _, newValue in markTouched(.password, if: newValue) }
                        caption(fieldErrors.password, field: .password)
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

                case .subsonic:
                    Section {
                        TextField("Server URL", text: $subsonicHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Navidrome server URL")
                            .onChange(of: subsonicHost) { _, newValue in markTouched(.host, if: newValue) }
                        caption(fieldErrors.host, field: .host)
                        TextField("Username", text: $subsonicUsername)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Navidrome username")
                            .onChange(of: subsonicUsername) { _, newValue in markTouched(.username, if: newValue) }
                        caption(fieldErrors.username, field: .username)
                        MaskedTextField(placeholder: "Password", text: $subsonicPassword, accessibilityLabel: "Navidrome password")
                            .onChange(of: subsonicPassword) { _, newValue in markTouched(.password, if: newValue) }
                        caption(fieldErrors.password, field: .password)
                    } header: {
                        Text("Server Settings")
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
                    Section {
                        TextField("Server URL", text: $absHost)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Audiobookshelf server URL")
                            .onChange(of: absHost) { _, newValue in markTouched(.host, if: newValue) }
                        caption(fieldErrors.host, field: .host)
                        TextField("Username", text: $absUsername)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Audiobookshelf username")
                            .onChange(of: absUsername) { _, newValue in markTouched(.username, if: newValue) }
                        caption(fieldErrors.username, field: .username)
                        MaskedTextField(placeholder: "Password", text: $absPassword, accessibilityLabel: "Audiobookshelf password")
                            .onChange(of: absPassword) { _, newValue in markTouched(.password, if: newValue) }
                        caption(fieldErrors.password, field: .password)
                    } header: {
                        Text("Server Settings")
                    } footer: {
                        Text("Include http:// or https://, e.g. https://abs.example.com. Requires server 2.26.0 or newer.")
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

                Section {
                    if isSaving {
                        HStack {
                            Spacer()
                            ProgressView("Adding account...")
                            Spacer()
                        }
                    } else {
                        Button {
                            save()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Add Account")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(!isValid)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Group Selection

    private var groupSelectionView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Enable Groups")
                    .font(.title.bold())
                Text("We found \(newGroupNames.count) groups. Choose which ones to enable.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            List {
                Section {
                    Button("Enable All") {
                        Task { await providerManager.setAllGroupsEnabled(true) }
                    }
                    .disabled(providerManager.enabledGroups == nil)
                    Button("Disable All") {
                        Task { await providerManager.setAllGroupsEnabled(false) }
                    }
                    .disabled(providerManager.enabledGroups?.isEmpty == true)
                }

                Section {
                    ForEach(newGroupNames, id: \.self) { group in
                        Toggle(isOn: Binding(
                            get: { providerManager.isGroupEnabled(group) },
                            set: { _ in Task { await providerManager.toggleGroupEnabled(group) } }
                        )) {
                            HStack {
                                Text(group)
                                Spacer()
                                if let count = providerManager.allGroupCounts[group] {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                Task {
                    await settingsViewModel.completeSetup()
                    onComplete()
                }
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Validation & Save

    private static let allowedSchemes: Set<String> = ["http", "https"]

    private var isSubsonicHTTP: Bool {
        guard connectionType == .subsonic,
              let url = URL(string: subsonicHost),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
    }

    private var isXtreamCodesHTTP: Bool {
        guard connectionType == .xtreamCodes,
              let url = URL(string: xcHost),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
    }

    private var isAudiobookshelfHTTP: Bool {
        guard connectionType == .audiobookshelf,
              let url = URL(string: absHost),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http"
    }

    // beads_mobilemusic-uxb.3: single source of truth for validation, shared
    // with AddProviderView via ProviderFormValidation (was duplicated here).
    private var validationKind: ProviderFormValidation.ProviderKind {
        switch connectionType {
        case .m3u: return .m3u
        case .xtreamCodes: return .xtreamCodes
        case .subsonic: return .subsonic
        case .audiobookshelf: return .audiobookshelf
        }
    }

    private var currentHostText: String {
        switch connectionType {
        case .m3u: return m3uURL
        case .xtreamCodes: return xcHost
        case .subsonic: return subsonicHost
        case .audiobookshelf: return absHost
        }
    }

    private var currentUsernameText: String {
        switch connectionType {
        case .m3u: return ""
        case .xtreamCodes: return xcUsername
        case .subsonic: return subsonicUsername
        case .audiobookshelf: return absUsername
        }
    }

    private var currentPasswordText: String {
        switch connectionType {
        case .m3u: return ""
        case .xtreamCodes: return xcPassword
        case .subsonic: return subsonicPassword
        case .audiobookshelf: return absPassword
        }
    }

    private var fieldErrors: ProviderFormValidation.Result {
        ProviderFormValidation.validate(
            kind: validationKind,
            name: name,
            host: currentHostText,
            username: currentUsernameText,
            password: currentPasswordText
        )
    }

    private var isValid: Bool {
        fieldErrors.isValid
    }

    private func save() {
        hasSubmitted = true
        isSaving = true
        error = nil

        let type: Provider.ProviderType
        switch connectionType {
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

        let provider = Provider(name: name, type: type)
        Task {
            await providerManager.addProvider(provider, enableAllGroups: true)
            if let loadError = providerManager.error {
                error = loadError
                isSaving = false
            } else {
                // Subsonic returns 0 channels (library loading is E2).
                // If there are no groups, skip the group-selection step and
                // complete setup directly — don't strand the user on an empty list.
                let groups = providerManager.allGroupCounts.keys.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                isSaving = false
                if groups.isEmpty {
                    await settingsViewModel.completeSetup()
                    onComplete()
                } else {
                    newGroupNames = groups
                    withAnimation { step = .groupSelection }
                }
            }
        }
    }
}
