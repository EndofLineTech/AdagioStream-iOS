import AdagioStreamCore
import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var showClearLogsAlert = false
    @State private var showShareSheet = false
    @State private var showShareWarning = false
    @State private var showExportSheet = false
    @State private var exportFileURL: URL?
    @State private var isExporting = false
    @State private var showDeleteWarning = false
    @State private var showDeleteConfirmation = false
    @State private var logSize = DebugLogger.shared.logFileSize()

    var body: some View {
        Form {
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

            Section {
                Button {
                    isExporting = true
                    Task {
                        let data = await DataExportService.exportAll(
                            providerManager: providerManager,
                            persistence: .shared
                        )
                        exportFileURL = try? DataExportService.writeExportFile(data)
                        isExporting = false
                        if exportFileURL != nil {
                            showExportSheet = true
                        }
                    }
                } label: {
                    HStack {
                        Label("Export My Data", systemImage: "square.and.arrow.up")
                        Spacer()
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isExporting)
            } footer: {
                Text("Exports your accounts (without passwords), favorites, saved songs, playlists, groups, and settings as a JSON file.")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteWarning = true
                } label: {
                    Label("Delete All My Data", systemImage: "trash")
                }
            } footer: {
                Text("Permanently deletes all app data including accounts, favorites, playlists, settings, cached images, and logs. This cannot be undone.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
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
        .alert("Delete All Data?", isPresented: $showDeleteWarning) {
            Button("Continue", role: .destructive) {
                showDeleteConfirmation = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently erase all your accounts, favorites, saved songs, playlists, settings, cached images, and logs. This cannot be undone.")
        }
        .alert("Are you sure?", isPresented: $showDeleteConfirmation) {
            Button("Delete Everything", role: .destructive) {
                Task {
                    await DataDeletionService.deleteAllData()
                    await providerManager.loadProviders()
                    await providerManager.loadChannels()
                    viewModel.settings = .default
                    NotificationCenter.default.post(name: .didDeleteAllData, object: nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is your last chance. All data will be permanently deleted and the app will reset to its initial state.")
        }
        .sheet(isPresented: $showExportSheet, onDismiss: {
            if let url = exportFileURL {
                try? FileManager.default.removeItem(at: url)
                exportFileURL = nil
            }
        }) {
            if let url = exportFileURL {
                ShareSheet(activityItems: [url])
                    .presentationDetents([.medium, .large])
            }
        }
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
