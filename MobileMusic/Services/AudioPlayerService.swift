import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import VLCKitSPM

@MainActor
final class AudioPlayerService: NSObject, ObservableObject, @preconcurrency VLCMediaPlayerDelegate {
    static let shared = AudioPlayerService()

    @Published var currentChannel: Channel?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var error: String?
    @Published var streamBitrateKbps: Double = 0
    @Published var statusText: String = ""

    private let mediaPlayer = VLCMediaPlayer()
    private var stateTimer: Timer?

    var channels: [Channel] = []
    var bufferDuration: TimeInterval = Constants.defaultBufferDuration

    private override init() {
        super.init()
        mediaPlayer.delegate = self
        configureAudioSession()
        configureRemoteCommands()
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
        stateTimer?.invalidate()

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

        // Poll state as a reliable fallback since VLC delegate
        // fires on a background thread that can miss MainActor updates
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
    }

    func pause() {
        mediaPlayer.pause()
        syncState()
        updateNowPlayingInfo()
    }

    func resume() {
        mediaPlayer.play()
        syncState()
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
        stateTimer?.invalidate()
        stateTimer = nil
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

    // MARK: - VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            self.syncState()
        }
    }

    // MARK: - State Sync

    private func syncState() {
        let state = mediaPlayer.state
        let playing = mediaPlayer.isPlaying

        switch state {
        case .playing:
            isPlaying = true
            isBuffering = false
            error = nil
        case .paused:
            isPlaying = false
            isBuffering = false
        case .buffering, .opening:
            isBuffering = true
        case .stopped:
            if currentChannel != nil {
                // Only clear if we didn't initiate the stop
                isPlaying = false
                isBuffering = false
            }
        case .error:
            isPlaying = false
            isBuffering = false
            error = "Stream playback error"
        case .ended:
            isPlaying = false
            isBuffering = false
        @unknown default:
            break
        }

        // Trust VLC's isPlaying as ground truth
        if playing && !isPlaying {
            isPlaying = true
            isBuffering = false
        }

        // Update stream stats
        updateStreamStats()
        updateNowPlayingInfo()
    }

    // MARK: - Stream Stats

    private func updateStreamStats() {
        guard currentChannel != nil else {
            statusText = ""
            streamBitrateKbps = 0
            return
        }

        if let media = mediaPlayer.media {
            let stats = media.statistics
            let bitrate = Double(stats.inputBitrate)
            if bitrate > 0 {
                // inputBitrate is in kb/s
                streamBitrateKbps = bitrate * 1000
            } else {
                let demux = Double(stats.demuxBitrate)
                if demux > 0 {
                    streamBitrateKbps = demux * 1000
                }
            }
        }

        if isBuffering {
            statusText = "Buffering... (cache: \(Int(bufferDuration))s)"
        } else if isPlaying {
            if streamBitrateKbps > 1 {
                let formatted = streamBitrateKbps >= 1000
                    ? String(format: "%.1f Mbps", streamBitrateKbps / 1000)
                    : "\(Int(streamBitrateKbps)) kbps"
                statusText = "Live \u{00B7} \(formatted)"
            } else {
                statusText = "Live"
            }
        } else {
            statusText = ""
        }
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
