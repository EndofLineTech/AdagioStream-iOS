import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import VLCKitSPM

@MainActor
final class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    @Published var currentChannel: Channel?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var error: String?

    private let mediaPlayer = VLCMediaPlayer()
    private var stateObserver: Any?

    var channels: [Channel] = []
    var bufferDuration: TimeInterval = Constants.defaultBufferDuration

    private override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        observePlayerState()
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            self.error = "Failed to configure audio session: \(error.localizedDescription)"
        }
    }

    // MARK: - Playback

    func play(channel: Channel) {
        mediaPlayer.stop()

        // Re-activate audio session
        try? AVAudioSession.sharedInstance().setActive(true)

        currentChannel = channel
        isBuffering = true
        isPlaying = false
        error = nil

        let media = VLCMedia(url: channel.streamURL)
        media.addOptions([
            "network-caching": Int(bufferDuration * 1000),
            "live-caching": Int(bufferDuration * 1000),
            "http-user-agent": "MobileMusic/1.0",
        ])

        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100
        mediaPlayer.play()
        updateNowPlayingInfo()
    }

    func pause() {
        mediaPlayer.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        mediaPlayer.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        mediaPlayer.stop()
        currentChannel = nil
        isPlaying = false
        isBuffering = false
        clearNowPlayingInfo()
    }

    func playNext() {
        guard let current = currentChannel,
              let index = channels.firstIndex(where: { $0.id == current.id }),
              index + 1 < channels.count else { return }
        play(channel: channels[index + 1])
    }

    func playPrevious() {
        guard let current = currentChannel,
              let index = channels.firstIndex(where: { $0.id == current.id }),
              index > 0 else { return }
        play(channel: channels[index - 1])
    }

    func updateBufferDuration(_ duration: TimeInterval) {
        bufferDuration = duration
    }

    // MARK: - State Observation

    private func observePlayerState() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "VLCMediaPlayerStateChanged"),
            object: mediaPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleStateChange()
            }
        }
    }

    private func handleStateChange() {
        let state = mediaPlayer.state

        switch state {
        case .playing:
            isPlaying = true
            isBuffering = false
            error = nil
        case .paused:
            isPlaying = false
            isBuffering = false
        case .buffering:
            isBuffering = true
        case .stopped:
            isPlaying = false
            isBuffering = false
        case .error:
            isPlaying = false
            isBuffering = false
            error = "Stream playback error"
        case .opening:
            isBuffering = true
        case .ended:
            isPlaying = false
            isBuffering = false
        @unknown default:
            break
        }

        updateNowPlayingInfo()
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        guard let channel = currentChannel else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: channel.name,
            MPMediaItemPropertyArtist: channel.group,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let logoURL = channel.logoURL {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: logoURL),
                   let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote Commands

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
    }
}
