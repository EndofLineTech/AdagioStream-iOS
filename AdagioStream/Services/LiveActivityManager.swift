import ActivityKit
import Combine
import Foundation
import UIKit

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    // Stored as Any? to avoid availability requirements on the property itself
    private var currentActivity: Any?
    private var cancellable: AnyCancellable?
    private var currentChannelID: String?
    private var artworkTask: Task<Void, Never>?

    private init() {
        cleanupOrphanedActivities()
    }

    // MARK: - Typed Accessor

    @available(iOS 16.2, *)
    private var typedActivity: Activity<NowPlayingAttributes>? {
        get { currentActivity as? Activity<NowPlayingAttributes> }
        set { currentActivity = newValue }
    }

    // MARK: - Observe Player State

    func observePlayerState(_ player: AudioPlayerService) {
        cancellable = player.$currentChannel
            .combineLatest(player.$isPlaying, player.$isBuffering)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] channel, isPlaying, isBuffering in
                guard let self else { return }
                self.handleStateChange(channel: channel, isPlaying: isPlaying, isBuffering: isBuffering)
            }
    }

    // MARK: - State Handling

    private func handleStateChange(channel: Channel?, isPlaying: Bool, isBuffering: Bool) {
        guard #available(iOS 16.2, *) else { return }

        guard let channel else {
            endActivity()
            return
        }

        let playbackState: NowPlayingAttributes.ContentState.PlaybackState
        if isPlaying {
            playbackState = .playing
        } else if isBuffering {
            playbackState = .buffering
        } else {
            playbackState = .paused
        }

        if currentChannelID != channel.id {
            endActivity()
            startActivity(for: channel, state: playbackState)
        } else {
            updateActivity(state: playbackState)
        }
    }

    // MARK: - Activity Lifecycle

    private func startActivity(for channel: Channel, state: NowPlayingAttributes.ContentState.PlaybackState) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = NowPlayingAttributes(
            channelName: channel.name,
            channelGroup: channel.group,
            channelID: channel.id
        )

        let contentState = NowPlayingAttributes.ContentState(
            playbackState: state,
            artworkData: nil
        )

        do {
            let content = ActivityContent(state: contentState, staleDate: nil)
            typedActivity = try Activity.request(
                attributes: attributes,
                content: content
            )
            currentChannelID = channel.id
        } catch {
            // Activity couldn't be started — not critical
        }

        // Fetch artwork async, then update
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let logoURL = channel.logoURL else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: logoURL) else { return }
            guard let image = UIImage(data: data) else { return }
            let resized = Self.resizeImage(image, maxDimension: 96)
            guard let pngData = resized.pngData() else { return }
            guard !Task.isCancelled else { return }
            self?.updateArtwork(pngData)
        }
    }

    private func updateActivity(state: NowPlayingAttributes.ContentState.PlaybackState) {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = typedActivity else { return }

        let contentState = NowPlayingAttributes.ContentState(
            playbackState: state,
            artworkData: activity.content.state.artworkData
        )

        Task {
            let content = ActivityContent(state: contentState, staleDate: nil)
            await activity.update(content)
        }
    }

    private func updateArtwork(_ data: Data) {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = typedActivity else { return }

        let contentState = NowPlayingAttributes.ContentState(
            playbackState: activity.content.state.playbackState,
            artworkData: data
        )

        Task {
            let content = ActivityContent(state: contentState, staleDate: nil)
            await activity.update(content)
        }
    }

    private func endActivity() {
        guard #available(iOS 16.2, *) else { return }

        artworkTask?.cancel()
        artworkTask = nil
        currentChannelID = nil

        guard let activity = typedActivity else { return }
        typedActivity = nil

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Cleanup

    private func cleanupOrphanedActivities() {
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<NowPlayingAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Image Helpers

    private static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
