// l31.2 — Per-track download control.
//
// A compact button that reflects download state for a single track:
//   • .notDownloaded  → download icon (arrow.down.circle) — tap to download
//   • .queued / .downloading → progress ring + cancel affordance
//   • .completed      → checkmark.circle.fill — tap to delete
//   • .failed         → exclamationmark.circle — tap to retry
//
// Consumers pass the track, api, and the DownloadManager environment object
// is used directly.

#if canImport(UIKit)
import SwiftUI

// MARK: - TrackDownloadButton

struct TrackDownloadButton: View {

    let track: Track
    let api: NavidromeAPI

    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var showDeleteConfirm = false

    private var record: DownloadRecord? {
        downloadManager.downloads.first { $0.id == track.id }
    }

    private var downloadProgress: DownloadProgress? {
        downloadManager.progress[track.id]
    }

    var body: some View {
        Group {
            switch downloadState {
            case .notDownloaded:
                downloadButton

            case .queued:
                queuedIndicator

            case .downloading:
                downloadingIndicator

            case .completed:
                completedButton

            case .failed:
                failedButton
            }
        }
        .confirmationDialog(
            "Remove Download?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Download", role: .destructive) {
                downloadManager.deleteDownload(trackID: track.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(track.title)\" from your device.")
        }
    }

    // MARK: - State derivation

    private enum TrackDownloadState {
        case notDownloaded
        case queued
        case downloading
        case completed
        case failed
    }

    private var downloadState: TrackDownloadState {
        guard let rec = record else { return .notDownloaded }
        switch rec.status {
        case .queued:   return .queued
        case .downloading: return .downloading
        case .completed:   return .completed
        case .failed, .paused: return .failed
        }
    }

    // MARK: - Sub-views

    private var downloadButton: some View {
        Button {
            downloadManager.download(track: track, via: api)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download \(track.title)")
        .accessibilityHint("Downloads this track for offline listening")
    }

    private var queuedIndicator: some View {
        Button {
            downloadManager.cancelDownload(trackID: track.id)
        } label: {
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Queued — tap to cancel download of \(track.title)")
        .accessibilityValue("Queued")
    }

    private var downloadingIndicator: some View {
        Button {
            downloadManager.cancelDownload(trackID: track.id)
        } label: {
            ZStack {
                if let prog = downloadProgress, let fraction = prog.fraction {
                    // Indeterminate ring with fraction overlay
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 20, height: 20)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accentColor)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Downloading \(track.title) — tap to cancel")
        .accessibilityValue(progressAccessibilityValue)
    }

    private var completedButton: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Downloaded — tap to delete \(track.title)")
        .accessibilityValue("Downloaded")
    }

    private var failedButton: some View {
        Button {
            downloadManager.download(track: track, via: api)
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download failed — tap to retry \(track.title)")
        .accessibilityValue(record?.error ?? "Failed")
    }

    // MARK: - Helpers

    private var progressAccessibilityValue: String {
        guard let prog = downloadProgress, let fraction = prog.fraction else {
            return "Downloading"
        }
        let pct = Int(fraction * 100)
        return "\(pct)% downloaded"
    }
}

// MARK: - Preview

#Preview("Download states") {
    let api = NavidromeAPI(
        host: URL(string: "https://demo.navidrome.org")!,
        username: "demo",
        password: "demo"
    )
    let track = Track(
        id: "t1",
        albumId: "a1",
        artistId: "ar1",
        title: "Sample Track",
        updatedAt: 0
    )
    return VStack(spacing: 0) {
        TrackDownloadButton(track: track, api: api)
    }
    .environmentObject(DownloadManager.shared)
}
#endif // canImport(UIKit)
