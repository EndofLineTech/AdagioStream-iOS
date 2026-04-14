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

    private enum SetupStep {
        case welcome
        case connectionType
        case credentials
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                stepContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .animation(.easeInOut(duration: 0.3), value: step)
            }
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
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "radio")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("Welcome to Adagio Stream")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Stream your favorite audio channels from M3U playlists or Xtream Codes providers.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    withAnimation { step = .connectionType }
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await settingsViewModel.completeSetup()
                        onComplete()
                    }
                } label: {
                    Text("Skip Setup")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                    icon: "music.note.list",
                    isSelected: connectionType == 0
                ) {
                    connectionType = 0
                }

                connectionCard(
                    title: "Xtream Codes",
                    description: "Connect with server URL, username, and password",
                    icon: "server.rack",
                    isSelected: connectionType == 1
                ) {
                    connectionType = 1
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            HStack(spacing: 16) {
                Button("Back") {
                    withAnimation { step = .welcome }
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation { step = .credentials }
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func connectionCard(title: String, description: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 44)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .white : .gray)
            }
            .padding(16)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            .foregroundStyle(isSelected ? .white : .primary)
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
            .padding(.top, 40)
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
            .scrollContentBackground(.hidden)

            HStack(spacing: 16) {
                Button("Back") {
                    error = nil
                    withAnimation { step = .connectionType }
                }
                .buttonStyle(.bordered)

                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        save()
                    } label: {
                        Text("Add Account")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                }
            }
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
            await providerManager.addProvider(provider)
            if let loadError = providerManager.error {
                error = loadError
                isSaving = false
            } else {
                await settingsViewModel.completeSetup()
                onComplete()
            }
        }
    }
}
