import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var showClearLogsAlert = false
    @State private var showShareSheet = false
    @State private var showShareWarning = false
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
