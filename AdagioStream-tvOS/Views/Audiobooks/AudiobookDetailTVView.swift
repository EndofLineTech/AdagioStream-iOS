import SwiftUI

// Audiobookshelf E4 / ciu.2 — tvOS audiobook detail + play.
//
// Mirrors the iOS AudiobookDetailView structure with focus-appropriate tvOS
// layout: cover + metadata + Resume/Play, and a chapter list. Resume and
// chapter navigation call straight into the shared AudioPlayerService+Audiobook
// path (playAudiobook seeds the resume position; a chapter row starts from that
// chapter's global start). No playback logic is reimplemented here.
struct AudiobookDetailTVView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    let book: Audiobook
    @EnvironmentObject private var audioPlayer: AudioPlayerService

    private var current: Audiobook { viewModel.selectedBook ?? book }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            cover
                .frame(width: 340, height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 24) {
                Text(current.title).font(.largeTitle).lineLimit(3)
                if let author = current.author, !author.isEmpty {
                    Text(author).font(.title2).foregroundStyle(.secondary)
                }
                if let duration = current.duration {
                    Text(Self.formatDuration(duration)).font(.title3).foregroundStyle(.secondary)
                }
                Button {
                    startPlayback()
                } label: {
                    Label(resumeLabel, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                chapterList
            }
            Spacer()
        }
        .padding(60)
        .task { await viewModel.loadDetail(for: book) }
        .onDisappear { viewModel.resetDetail() }
    }

    @ViewBuilder private var chapterList: some View {
        if !viewModel.chapters.isEmpty {
            List {
                Section("Chapters") {
                    ForEach(viewModel.chapters, id: \.id) { chapter in
                        Button {
                            startPlayback(from: chapter.start)
                        } label: {
                            HStack {
                                let isCurrent = audioPlayer.currentAudiobook?.id == current.id
                                    && audioPlayer.currentChapter?.id == chapter.id
                                Image(systemName: isCurrent ? "play.circle.fill" : "circle")
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                Text(chapter.title).lineLimit(2)
                                Spacer()
                                Text(Self.formatTimestamp(chapter.start))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // uxd.3: the play/circle glyph otherwise reads as its
                        // raw SF Symbol name ("play circle fill") to VoiceOver.
                        .accessibilityLabel("\(chapter.title)\(audioPlayer.currentAudiobook?.id == current.id && audioPlayer.currentChapter?.id == chapter.id ? ", now playing" : "")")
                    }
                }
            }
            .frame(maxHeight: 500)
        } else if viewModel.detailState == .loading {
            ProgressView("Loading chapters…")
        }
    }

    @ViewBuilder private var cover: some View {
        if let url = viewModel.coverURLs[book.id] {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.secondary.opacity(0.2))
            Image(systemName: "book.closed").font(.system(size: 96)).foregroundStyle(.secondary)
        }
    }

    private var resumeLabel: String {
        current.progress > 0 && !current.isFinished ? "Resume" : "Play"
    }

    private func startPlayback(from global: Double? = nil) {
        audioPlayer.playAudiobook(current, via: viewModel.audiobookshelfAPI, startGlobalTime: global)
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
