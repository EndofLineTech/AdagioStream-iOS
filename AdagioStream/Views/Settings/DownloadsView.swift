// l31.2 — Downloads / offline-music storage management screen.
// l31.3 — Added playback: tap a track row to play it from disk.
//
// Shows all completed downloads with track IDs and file sizes, total storage
// consumed, per-item delete, and a "Clear All" action.
//
// DownloadRecord carries only the track ID (no title), because the downloads
// table has no foreign-key to tracks (intentional — survives library-cache wipes).
// If the track is still in the library cache, the title is looked up from
// NavidromeStore; otherwise the track ID is shown.
//
// Playback (l31.3): tapping a row calls AudioPlayerService.setQueue with all
// downloaded tracks starting at the tapped one.  When the full Track record is
// not in the library cache a minimal placeholder is constructed from the
// DownloadRecord so VLC can still resolve the local file URL.
//
// Surfaced from Settings via a "Downloads" NavigationLink.

#if canImport(UIKit)
import SwiftUI

struct DownloadsView: View {

    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var providerManager: ProviderManager
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    @State private var showClearAllConfirm = false
    @State private var trackTitles: [String: String] = [:]  // trackID → title
    @State private var resolvedTracks: [String: Track] = [:] // trackID → Track (cache or minimal)

    private var completedDownloads: [DownloadRecord] {
        downloadManager.downloads.filter { $0.status == .completed }
    }

    // MARK: - Audiobook / podcast downloads (E4 / 6b5.2)
    //
    // `audiobookDownloads` (GRDB `audiobook_downloads` table) holds BOTH books
    // and podcast episodes — an episode's id is namespaced
    // "ep#<showId>#<episodeId>" (`AudiobookDownloadRecord.isEpisodeDownload`),
    // so splitting on that flag distinguishes the two without a second table.
    // Purely additive to this view: the music-track section/state above is
    // completely untouched.

    private var completedBookDownloads: [AudiobookDownloadRecord] {
        downloadManager.audiobookDownloads.filter { $0.status == .completed && !$0.isEpisodeDownload }
    }

    private var completedEpisodeDownloads: [AudiobookDownloadRecord] {
        downloadManager.audiobookDownloads.filter { $0.status == .completed && $0.isEpisodeDownload }
    }

    var body: some View {
        List {
            // Offline mode toggle (l31.3)
            Section {
                Toggle(isOn: offlineModeBinding) {
                    Label("Offline Mode", systemImage: "wifi.slash")
                }
                .accessibilityLabel("Offline Mode")
                .accessibilityHint("When on, the Music tab shows only downloaded tracks and makes no network requests")
            } footer: {
                Text("When enabled, the Music tab shows only your downloaded tracks and won't make any network requests.")
            }

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
                            onPlay: {
                                playDownloads(startingAt: record.id)
                            },
                            onDelete: {
                                downloadManager.deleteDownload(trackID: record.id)
                            }
                        )
                    }
                }
            } header: {
                Text("Downloaded Tracks")
            }

            // Audiobook downloads (E4 / 6b5.2) — additive; music section above unchanged.
            if !completedBookDownloads.isEmpty {
                Section {
                    ForEach(completedBookDownloads, id: \.id) { record in
                        DownloadedAudiobookRow(record: record) {
                            downloadManager.deleteBookDownload(itemID: record.id)
                        }
                    }
                } header: {
                    Text("Audiobooks")
                }
            }

            // Podcast episode downloads (E4 / 6b5.2) — shows show title + episode
            // title so an episode reads distinctly from an audiobook row.
            if !completedEpisodeDownloads.isEmpty {
                Section {
                    ForEach(completedEpisodeDownloads, id: \.id) { record in
                        DownloadedEpisodeRow(record: record) {
                            if let ids = AudiobookDownloadRecord.parseEpisodeRecordID(record.id) {
                                downloadManager.deleteEpisodeDownload(showID: ids.showID, episodeID: ids.episodeID)
                            }
                        }
                    }
                } header: {
                    Text("Podcasts")
                }
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

    // MARK: - Offline mode binding

    private var offlineModeBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.settings.offlineMode },
            set: { newValue in
                Task { await settingsViewModel.updateOfflineMode(newValue) }
            }
        )
    }

    // MARK: - Playback

    /// Builds a queue from all completed downloads and starts playing at the
    /// tapped track.  Resolves each track from the library cache; falls back to
    /// a minimal placeholder Track so VLC can still locate the local file.
    private func playDownloads(startingAt trackID: String) {
        guard let api = providerManager.subsonicAPI else { return }
        let downloads = completedDownloads
        guard !downloads.isEmpty else { return }

        // Build the full queue of Track objects.
        let queue = downloads.map { record in
            resolvedTracks[record.id] ?? minimalTrack(from: record)
        }

        // Find the index of the tapped track.
        let startIndex = downloads.firstIndex(where: { $0.id == trackID }) ?? 0
        audioPlayer.setQueue(queue, startIndex: startIndex, via: api)
    }

    // MARK: - Helpers

    /// Attempts to look up track titles and full Track records for completed
    /// download records from the NavidromeStore library cache.  Falls back
    /// gracefully when the cache does not have a matching track row.
    private func resolveTrackTitles() {
        let store = NavidromeStore.shared
        var titles: [String: String] = [:]
        var tracks: [String: Track] = [:]
        for record in completedDownloads {
            if let track = try? store.writer.read({ db in
                try Track.fetchOne(db, key: record.id)
            }) {
                titles[record.id] = track.title
                tracks[record.id] = track
            }
        }
        trackTitles = titles
        resolvedTracks = tracks
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Minimal Track construction (l31.3)

/// Constructs a minimal `Track` placeholder from a `DownloadRecord` for tracks
/// that are no longer in the library cache.  The local file can still be
/// resolved by `DownloadManager.localFileURL(forTrackID:)` using the `id`.
/// All optional metadata fields are left nil; only `id` is strictly required
/// for local-first playback resolution.
public func minimalTrack(from record: DownloadRecord) -> Track {
    Track(
        id: record.id,
        albumId: "",
        artistId: "",
        title: record.id,  // track ID as placeholder title — displayed until the cache refreshes
        updatedAt: record.updatedAt
    )
}

// MARK: - Downloaded track row

private struct DownloadedTrackRow: View {
    let record: DownloadRecord
    let title: String?
    let onPlay: () -> Void
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
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle)\(fileSizeText.map { ", \($0)" } ?? ""), downloaded")
        .accessibilityHint("Tap to play")
        .accessibilityAction(named: "Play") { onPlay() }
        .accessibilityAction(named: "Delete") { onDelete() }
    }
}

// MARK: - Downloaded audiobook / episode rows (E4 / 6b5.2)

/// One downloaded audiobook. No play action here (tapping into
/// AudiobookLibraryView already covers playback) — this screen is
/// manage/delete only, matching the storage-management scope of this view.
private struct DownloadedAudiobookRow: View {
    let record: AudiobookDownloadRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                if let author = record.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(record.title)")
            .accessibilityHint("Removes this audiobook from your device")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.title), downloaded audiobook")
        .accessibilityAction(named: "Delete", onDelete)
    }
}

/// One downloaded podcast episode — shows the SHOW title (in `record.author`,
/// set from `AudiobookDownloadRecord.forEpisode`'s `showTitle` param) above the
/// episode title, so it reads distinctly from an audiobook row at a glance.
private struct DownloadedEpisodeRow: View {
    let record: AudiobookDownloadRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let showTitle = record.author, !showTitle.isEmpty {
                    Text(showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(record.title).font(.body).foregroundStyle(.primary).lineLimit(2)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(record.title)")
            .accessibilityHint("Removes this episode from your device")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.title), downloaded episode\(record.author.map { " of \($0)" } ?? "")")
        .accessibilityAction(named: "Delete", onDelete)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DownloadsView()
    }
    .environmentObject(DownloadManager.shared)
    .environmentObject(ProviderManager())
    .environmentObject(AudioPlayerService.shared)
    .environmentObject(SettingsViewModel(audioPlayer: AudioPlayerService.shared))
}
#endif // canImport(UIKit)
