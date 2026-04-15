import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var showClearFavoritesAlert = false
    @State private var showClearLogsAlert = false
    @State private var showShareSheet = false
    @State private var showShareWarning = false
    @State private var logSize = DebugLogger.shared.logFileSize()
    @State private var newPrefix = ""

    var body: some View {
        Form {
            // MARK: - Sorting
            Section {
                Picker("Channel Sort", selection: channelSortBinding) {
                    ForEach(ChannelSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                Picker("Group Sort", selection: groupSortBinding) {
                    ForEach(ChannelSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
            } header: {
                Text("Sorting")
            }

            // MARK: - Sort Prefixes
            Section {
                ForEach(viewModel.settings.sortPrefixes, id: \.self) { prefix in
                    Text(prefix)
                }
                .onDelete { indexSet in
                    viewModel.settings.sortPrefixes.remove(atOffsets: indexSet)
                    Task { await viewModel.saveSettings() }
                }
                HStack {
                    TextField("New prefix...", text: $newPrefix)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        let trimmed = newPrefix.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              !viewModel.settings.sortPrefixes.contains(trimmed) else { return }
                        viewModel.settings.sortPrefixes.append(trimmed)
                        newPrefix = ""
                        Task { await viewModel.saveSettings() }
                    }
                    .disabled(newPrefix.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Sort Prefixes")
            } footer: {
                Text("Channel names starting with these prefixes will be sorted by the text after the prefix (e.g. \"Radio: Jazz\" sorts under J).")
            }

            // MARK: - Debug Logs
            Section {
                Toggle("Enable Debug Logging", isOn: debugLoggingBinding)

                Button {
                    showShareWarning = true
                } label: {
                    HStack {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                        Spacer()
                        Text(logSize)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!FileManager.default.fileExists(atPath: DebugLogger.shared.logFileURL.path))

                Button(role: .destructive) {
                    showClearLogsAlert = true
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                .disabled(!FileManager.default.fileExists(atPath: DebugLogger.shared.logFileURL.path))
            } header: {
                Text("Debug Logs")
            } footer: {
                Text("When enabled, logs record player, CarPlay, call, and Siri events for troubleshooting. Share them via AirDrop, email, or save to Files.")
            }

            // MARK: - Data
            Section("Data") {
                Button(role: .destructive) {
                    showClearFavoritesAlert = true
                } label: {
                    Label("Clear All Favorites", systemImage: "star.slash")
                }
                .disabled(providerManager.favoriteChannels.isEmpty)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Favorites", isPresented: $showClearFavoritesAlert) {
            Button("Clear", role: .destructive) {
                Task { await providerManager.clearFavorites() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all \(providerManager.favoriteChannels.count) channels from your favorites?")
        }
        .alert("Clear Logs", isPresented: $showClearLogsAlert) {
            Button("Clear", role: .destructive) {
                DebugLogger.shared.clearLogs()
                logSize = DebugLogger.shared.logFileSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all debug log files?")
        }
        .alert("Share Debug Logs", isPresented: $showShareWarning) {
            Button("Share") { showShareSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Log files may contain channel names, server addresses, and connection details. Review the file before sharing publicly.")
        }
        .sheet(isPresented: $showShareSheet) {
            logSize = DebugLogger.shared.logFileSize()
        } content: {
            ShareSheet(activityItems: [DebugLogger.shared.logFileURL])
                .presentationDetents([.medium, .large])
        }
    }

    private var channelSortBinding: Binding<ChannelSortOrder> {
        Binding(
            get: { viewModel.settings.channelSortOrder },
            set: { newValue in
                Task { await viewModel.updateChannelSortOrder(newValue, providerManager: providerManager) }
            }
        )
    }

    private var groupSortBinding: Binding<ChannelSortOrder> {
        Binding(
            get: { viewModel.settings.groupSortOrder },
            set: { newValue in
                Task { await viewModel.updateGroupSortOrder(newValue, providerManager: providerManager) }
            }
        )
    }

    private var debugLoggingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.debugLoggingEnabled },
            set: { newValue in
                Task { await viewModel.updateDebugLogging(newValue) }
            }
        )
    }
}
