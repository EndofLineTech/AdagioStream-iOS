import ActivityKit
import SwiftUI
import WidgetKit

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            // MARK: - Lock Screen Banner
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - Expanded
                DynamicIslandExpandedRegion(.leading) {
                    artworkView(data: context.state.artworkData, size: 48)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.channelName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.channelGroup)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    playbackIcon(state: context.state.playbackState)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(statusText(for: context.state.playbackState))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                artworkView(data: context.state.artworkData, size: 24)
            } compactTrailing: {
                playbackIcon(state: context.state.playbackState)
                    .font(.caption)
            } minimal: {
                playbackIcon(state: context.state.playbackState)
                    .font(.caption)
            }
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<NowPlayingAttributes>) -> some View {
        HStack(spacing: 12) {
            artworkView(data: context.state.artworkData, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.channelName)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.attributes.channelGroup)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            playbackIcon(state: context.state.playbackState)
                .font(.title2)
        }
        .padding()
    }

    // MARK: - Components

    @ViewBuilder
    private func artworkView(data: Data?, size: CGFloat) -> some View {
        if let data, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "radio")
                .font(.system(size: size * 0.4))
                .frame(width: size, height: size)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        }
    }

    @ViewBuilder
    private func playbackIcon(state: NowPlayingAttributes.ContentState.PlaybackState) -> some View {
        switch state {
        case .playing:
            if #available(iOS 17.0, *) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
            }
        case .buffering:
            ProgressView()
        case .paused:
            Image(systemName: "pause.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(for state: NowPlayingAttributes.ContentState.PlaybackState) -> String {
        switch state {
        case .playing: return "Live"
        case .buffering: return "Buffering..."
        case .paused: return "Paused"
        }
    }
}
