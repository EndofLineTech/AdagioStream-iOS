import AdagioStreamCore
import SwiftUI

struct WelcomeSetupView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var step: SetupStep = .welcome
    @State private var connectionType: Int = 0 // 0 = M3U, 1 = Xtream Codes

    // Shared fields
    @State private var name = ""

    // M3U fields
    @State private var m3uURL = ""
    @State private var epgURL = ""

    // Xtream Codes fields
    @State private var xcHost = ""
    @State private var xcUsername = ""
    @State private var xcPassword = ""

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
        case .credentials:
            Button {
                error = nil
                withAnimation { step = .connectionType }
            } label: {
                Image(systemName: "chevron.backward")
            }
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
                Text("Stream your favorite audio channels from M3U playlists or Xtream Codes providers.")
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
                    connectionType = 0
                    withAnimation { step = .credentials }
                }

                connectionCard(
                    title: "Xtream Codes",
                    description: "Connect with server URL, username, and password",
                    icon: "server.rack"
                ) {
                    connectionType = 1
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

    private var credentialsView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(connectionType == 0 ? "M3U Playlist" : "Xtream Codes")
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
                }

                if connectionType == 0 {
                    Section("Playlist Settings") {
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
                    Section("Server Settings") {
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

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if connectionType == 0 {
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

    private func save() {
        isSaving = true
        error = nil

        let type: Provider.ProviderType
        if connectionType == 0 {
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

        let provider = Provider(name: name, type: type)
        Task {
            await providerManager.addProvider(provider, enableAllGroups: true)
            if let loadError = providerManager.error {
                error = loadError
                isSaving = false
            } else {
                newGroupNames = providerManager.allGroupCounts.keys.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                isSaving = false
                withAnimation { step = .groupSelection }
            }
        }
    }
}
