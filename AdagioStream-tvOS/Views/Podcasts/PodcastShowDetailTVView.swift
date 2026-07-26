import SwiftUI

// Podcast E5 / hky.2 — tvOS show detail + episode list.
//
// Mirrors AudiobookDetailTVView's structure: cover + metadata, then a list —
// chapters there, episodes here. Tapping an episode plays it straight from
// the row (no separate detail screen, matching the audiobook chapter row's
// tap-to-play-from-here behavior) via the shared
// AudioPlayerService.playPodcastEpisode path with a whole-show
// PodcastPlaybackContext so auto-play-next-episode works. No playback logic
// is reimplemented here.
struct PodcastShowDetailTVView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    let show: PodcastShow
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var providerManager: ProviderManager

    private var episodes: [ABSEpisodeDTO] {
        PodcastPlaybackContext.sortedEpisodes(viewModel.selectedShowEpisodes, order: .newestFirst)
    }

    private var context: PodcastPlaybackContext {
        PodcastPlaybackContext(libraryItemId: show.id, showTitle: show.title, episodes: episodes, order: .newestFirst)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            cover
                .frame(width: 340, height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 24) {
                Text(show.title).font(.largeTitle).lineLimit(3)
                if let author = show.author, !author.isEmpty {
                    Text(author).font(.title2).foregroundStyle(.secondary)
                }
                episodeList
            }
            Spacer()
        }
        .padding(60)
        .task { await viewModel.loadShowDetail(show) }
        .onDisappear { viewModel.resetShowDetail() }
    }

    @ViewBuilder private var episodeList: some View {
        switch viewModel.showDetailState {
        case .loaded:
            List {
                Section("Episodes") {
                    ForEach(episodes, id: \.id) { episode in
                        Button {
                            play(episode)
                        } label: {
                            HStack {
                                let isCurrent = audioPlayer.currentAudiobook?.id == episode.id
                                Image(systemName: isCurrent ? "play.circle.fill" : "circle")
                                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(episode.title ?? "Episode").lineLimit(2)
                                    if let dateText = PodcastShowDetailTVView.formattedPubDate(episode.pubDate) {
                                        Text(dateText).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let duration = episode.duration {
                                    Text(AudiobookDetailTVView.formatDuration(duration))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        // uxd.3: the play/circle glyph otherwise reads as its
                        // raw SF Symbol name ("play circle fill") to VoiceOver.
                        .accessibilityLabel("\(episode.title ?? "Episode")\(audioPlayer.currentAudiobook?.id == episode.id ? ", now playing" : "")")
                    }
                }
            }
            .frame(maxHeight: 600)
        case .empty:
            Text("No episodes.").foregroundStyle(.secondary)
        case .error(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("Couldn't load episodes").font(.headline)
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { Task { await viewModel.loadShowDetail(show) } }
            }
        case .idle, .loading:
            ProgressView("Loading episodes…")
        }
    }

    @ViewBuilder private var cover: some View {
        if let url = viewModel.showCoverURLs[show.id] {
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
            Image(systemName: "mic").font(.system(size: 96)).foregroundStyle(.secondary)
        }
    }

    private func play(_ episode: ABSEpisodeDTO) {
        guard let api = providerManager.audiobookshelfAPI else { return }
        audioPlayer.playPodcastEpisode(episode, via: api, context: context, startGlobalTime: episode.userMediaProgress?.currentTime)
    }

    /// Localized display date for an episode's `pubDate`. Parses via the shared
    /// `PodcastPlaybackContext.parsePubDate` (same RFC-2822 parser iOS's
    /// PodcastEpisodeRowView.formattedPubDate uses — duplicated here rather than
    /// shared since that view lives under the iOS-only Views/ tree tvOS excludes).
    static func formattedPubDate(_ pubDate: String?) -> String? {
        guard let date = PodcastPlaybackContext.parsePubDate(pubDate) else { return nil }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }
}
