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
    private var currentArtwork: MPMediaItemArtwork?
    private var lastPlayedChannel: Channel?

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

        let channelChanged = currentChannel?.id != channel.id
        currentChannel = channel
        isBuffering = true
        isPlaying = false
        error = nil
        streamBitrateKbps = 0
        statusText = ""
        if channelChanged {
            currentArtwork = nil
            fetchArtwork(for: channel)
        }

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
        stateTimer?.invalidate()
        stateTimer = nil
        mediaPlayer.stop()
        isPlaying = false
        isBuffering = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard let channel = currentChannel ?? lastPlayedChannel else { return }
        play(channel: channel)
    }

    func togglePlayPause() {
        if isPlaying || isBuffering {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        stateTimer?.invalidate()
        stateTimer = nil
        mediaPlayer.stop()
        lastPlayedChannel = currentChannel
        currentChannel = nil
        isPlaying = false
        isBuffering = false
        currentArtwork = nil
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
        let vlcIsPlaying = mediaPlayer.isPlaying
        let vlcState = mediaPlayer.state

        // VLC reports .buffering state and isPlaying=false continuously
        // for live streams even while audio is actively playing.
        // Use demux bitrate as a reliable indicator of actual playback.
        let hasDataFlow: Bool = {
            guard let media = mediaPlayer.media else { return false }
            let stats = media.statistics
            return stats.demuxBitrate > 0 || stats.inputBitrate > 0
        }()

        if vlcIsPlaying || vlcState == .playing {
            isPlaying = true
            isBuffering = false
            error = nil
        } else if hasDataFlow && (vlcState == .buffering || vlcState == .opening) {
            // VLC says buffering but data is flowing — audio is actually playing
            isPlaying = true
            isBuffering = false
            error = nil
        } else {
            switch vlcState {
            case .buffering, .opening:
                isBuffering = true
            case .paused:
                isPlaying = false
                isBuffering = false
            case .stopped:
                if currentChannel != nil {
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
            default:
                break
            }
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
            // demuxBitrate reflects the actual media bitrate being decoded,
            // while inputBitrate fluctuates as the network buffer fills/drains
            let demux = Double(stats.demuxBitrate)
            let input = Double(stats.inputBitrate)
            let currentKbps = max(demux, input) * 1000

            if currentKbps > 1 {
                // Keep the highest observed bitrate as the stable value
                // since instantaneous rates dip when buffers are full
                if currentKbps > streamBitrateKbps {
                    streamBitrateKbps = currentKbps
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

        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        if isPlaying {
            center.playbackState = .playing
        } else if isBuffering {
            center.playbackState = .playing
        } else if currentChannel != nil {
            center.playbackState = .paused
        }
    }

    private func fetchArtwork(for channel: Channel) {
        guard let logoURL = channel.logoURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: logoURL),
                  let image = UIImage(data: data) else { return }
            guard self.currentChannel?.id == channel.id else { return }
            self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
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
