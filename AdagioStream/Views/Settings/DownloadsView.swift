// l31.2 — Downloads / offline-music storage management screen.
//
// Shows all completed downloads with track IDs and file sizes, total storage
// consumed, per-item delete, and a "Clear All" action.
//
// DownloadRecord carries only the track ID (no title), because the downloads
// table has no foreign-key to tracks (intentional — survives library-cache wipes).
// If the track is still in the library cache, the title is looked up from
// NavidromeStore; otherwise the track ID is shown.
//
// Surfaced from Settings via a "Downloads" NavigationLink.

#if canImport(UIKit)
import SwiftUI

struct DownloadsView: View {

    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var showClearAllConfirm = false
    @State private var trackTitles: [String: String] = [:]  // trackID → title

    private var completedDownloads: [DownloadRecord] {
        downloadManager.downloads.filter { $0.status == .completed }
    }

    var body: some View {
        List {
            // Storage summary section
            Section {
                HStack {
                    Label("Storage Used", systemImage: "internaldrive")
                    Spacer()
                    Text(formattedBytes(downloadManager.totalDownloadedBytes()))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Storage used: \(formattedBytes(downloadManager.totalDownloadedBytes()))")
                }
                .accessibilityElement(children: .combine)
            }

            // Downloads list
            Section {
                if completedDownloads.isEmpty {
                    Text("No downloaded tracks")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No downloaded tracks")
                } else {
                    ForEach(completedDownloads, id: \.id) { record in
                        DownloadedTrackRow(
                            record: record,
                            title: trackTitles[record.id],
                            onDelete: {
                                downloadManager.deleteDownload(trackID: record.id)
                            }
                        )
                    }
                }
            } header: {
                Text("Downloaded Tracks")
            }

            // Clear all
            if !completedDownloads.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Label("Clear All Downloads", systemImage: "trash")
                    }
                    .accessibilityLabel("Clear all downloads")
                    .accessibilityHint("Deletes all downloaded tracks from this device")
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear All Downloads?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                downloadManager.clearAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all downloaded tracks from this device. This cannot be undone.")
        }
        .task {
            resolveTrackTitles()
        }
        .onChange(of: downloadManager.downloads) { _, _ in
            resolveTrackTitles()
        }
    }

    // MARK: - Helpers

    /// Attempts to look up track titles for completed download records from the
    /// NavidromeStore library cache.  Falls back gracefully when the cache does
    /// not have a matching track row.
    private func resolveTrackTitles() {
        let store = NavidromeStore.shared
        var titles: [String: String] = [:]
        for record in completedDownloads {
            if let track = try? store.writer.read({ db in
                try Track.fetchOne(db, key: record.id)
            }) {
                titles[record.id] = track.title
            }
        }
        trackTitles = titles
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Downloaded track row

private struct DownloadedTrackRow: View {
    let record: DownloadRecord
    let title: String?
    let onDelete: () -> Void

    private var displayTitle: String {
        title ?? record.id
    }

    private var fileSizeText: String? {
        guard let path = record.localPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64, size > 0
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(1)

                if let size = fileSizeText {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(displayTitle)")
            .accessibilityHint("Removes this track from your device")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle)\(fileSizeText.map { ", \($0)" } ?? ""), downloaded")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DownloadsView()
    }
    .environmentObject(DownloadManager.shared)
}
#endif // canImport(UIKit)
