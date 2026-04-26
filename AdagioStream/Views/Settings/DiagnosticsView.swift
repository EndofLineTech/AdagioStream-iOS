import SwiftUI
import UIKit

/// Local-only diagnostics screen exposing the iCloud Keychain attribute
/// migration counters (see `MigrationDiagnostics` and bead 9nl.2).
///
/// Per Phase 0.5 G6: no analytics, no telemetry, no network. The user may
/// copy the snapshot to the clipboard to voluntarily share with support.
struct DiagnosticsView: View {
    @StateObject private var diagnostics = MigrationDiagnostics.shared
    @State private var showCopyConfirmation = false

    var body: some View {
        Form {
            Section {
                row(label: "Items found", value: "\(snapshot.itemsFound)")
                row(label: "Migrated", value: "\(snapshot.itemsMigrated)")
                row(label: "Failed", value: "\(snapshot.itemsFailed)")
                row(label: "Skipped", value: "\(snapshot.itemsSkipped)")
                row(label: "Last run", value: lastRunString)
                row(label: "Completed", value: snapshot.migrationCompleted ? "Yes" : "No")
            } header: {
                Text("Keychain Sync Migration")
            } footer: {
                Text("These counters are stored on this device only. Adagio Stream does not collect analytics or send this data anywhere.")
            }

            if let error = snapshot.lastError, !error.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Last Error")
                }
            }

            Section {
                Button {
                    UIPasteboard.general.string = clipboardText
                    showCopyConfirmation = true
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text("Copies the counters above as plain text. You can then paste into a support email — nothing is sent automatically.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Copied", isPresented: $showCopyConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Diagnostics text was copied to the clipboard.")
        }
    }

    private var snapshot: MigrationDiagnostics.Snapshot { diagnostics.snapshot }

    private var lastRunString: String {
        guard let date = snapshot.lastRun else { return "Never" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private var clipboardText: String {
        var lines: [String] = []
        lines.append("Adagio Stream — Keychain Sync Migration Diagnostics")
        lines.append("Items found:    \(snapshot.itemsFound)")
        lines.append("Migrated:       \(snapshot.itemsMigrated)")
        lines.append("Failed:         \(snapshot.itemsFailed)")
        lines.append("Skipped:        \(snapshot.itemsSkipped)")
        lines.append("Last run:       \(lastRunString)")
        lines.append("Completed:      \(snapshot.migrationCompleted ? "Yes" : "No")")
        if let error = snapshot.lastError, !error.isEmpty {
            lines.append("Last error:     \(error)")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
#endif
