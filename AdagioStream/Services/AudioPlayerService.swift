import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published var currentChannel: Channel?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var error: String?
    @Published var streamBitrateKbps: Double = 0
    @Published var statusText: String = ""

    private enum Backend {
        case none
        case avPlayer
        case mpv
    }

    private let avPlayer = AVPlayer()
    private let mpvPlayer = MPVAudioPlayer()
    private var activeBackend: Backend = .none
    private var cancellables = Set<AnyCancellable>()
    private var currentArtwork: MPMediaItemArtwork?
    private var lastPlayedChannel: Channel?
    private var wasPlayingBeforeInterruption = false
    private var isActiveSession = false
    private var bitrateTimer: Timer?
    private var lastToggleTime: Date = .distantPast

    var channels: [Channel] = []
    var bufferDuration: TimeInterval = Constants.defaultBufferDuration

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeAVPlayer()
        configureMPVCallbacks()
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc nonisolated private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        Task { @MainActor in
            switch type {
            case .began:
                wasPlayingBeforeInterruption = isPlaying || isBuffering
            case .ended:
                if wasPlayingBeforeInterruption {
                    wasPlayingBeforeInterruption = false
                    try? AVAudioSession.sharedInstance().setActive(true)
                    resume()
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Backend Selection

    /// Returns true if the URL should use AVPlayer (HLS), false for MPV (raw TS, etc.)
    private func shouldUseAVPlayer(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m3u8", "m3u":
            return true
        case "ts":
            return false
        default:
            // For unknown extensions, try AVPlayer first (fallback handled on error)
            return true
        }
    }

    // MARK: - AVPlayer Observation

    private func observeAVPlayer() {
        avPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.activeBackend == .avPlayer, self.isActiveSession else { return }
                switch status {
                case .playing:
                    self.isPlaying = true
                    self.isBuffering = false
                    self.error = nil
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                case .paused:
                    break
                @unknown default:
                    break
                }
                self.updateStreamStats()
                self.updateNowPlayingInfo()
            }
            .store(in: &cancellables)

        avPlayer.publisher(for: \.currentItem?.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.activeBackend == .avPlayer else { return }
                switch status {
                case .failed:
                    let itemError = self.avPlayer.currentItem?.error as NSError?
                    // If AVPlayer failed and this was an unknown extension, fall back to MPV
                    if let channel = self.currentChannel {
                        let ext = channel.streamURL.pathExtension.lowercased()
                        if ext != "m3u8" && ext != "m3u" {
                            self.playWithMPV(channel: channel)
                            return
                        }
                    }
                    self.isPlaying = false
                    self.isBuffering = false
                    self.error = itemError?.localizedDescription ?? "Stream playback error"
                    self.updateNowPlayingInfo()
                case .readyToPlay:
                    self.error = nil
                default:
                    break
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      self.activeBackend == .avPlayer,
                      let item = notification.object as? AVPlayerItem,
                      item == self.avPlayer.currentItem else { return }
                self.isPlaying = false
                self.isBuffering = false
                self.error = "Stream playback failed"
                self.updateNowPlayingInfo()
            }
            .store(in: &cancellables)
    }

    // MARK: - MPV Callbacks

    private func configureMPVCallbacks() {
        mpvPlayer.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.activeBackend == .mpv, self.isActiveSession else { return }
                switch state {
                case .idle:
                    self.isPlaying = false
                    self.isBuffering = false
                case .loading:
                    self.isBuffering = true
                case .playing:
                    self.isPlaying = true
                    self.isBuffering = false
                    self.error = nil
                case .paused:
                    self.isPlaying = false
                    self.isBuffering = false
                case .error(let msg):
                    self.isPlaying = false
                    self.isBuffering = false
                    self.error = msg
                }
                self.updateStreamStats()
                self.updateNowPlayingInfo()
            }
        }

        mpvPlayer.onBitrateUpdate = { [weak self] kbps in
            Task { @MainActor [weak self] in
                guard let self, self.activeBackend == .mpv else { return }
                if kbps > self.streamBitrateKbps {
                    self.streamBitrateKbps = kbps
                }
                self.updateStreamStats()
            }
        }
    }

    // MARK: - Playback

    func play(channel: Channel) {
        // Stop any current playback from either backend
        stopCurrentBackend()

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

        if shouldUseAVPlayer(for: channel.streamURL) {
            playWithAVPlayer(channel: channel)
        } else {
            playWithMPV(channel: channel)
        }
    }

    private func playWithAVPlayer(channel: Channel) {
        stopCurrentBackend()
        activeBackend = .avPlayer

        let asset = AVURLAsset(url: channel.streamURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = bufferDuration

        avPlayer.replaceCurrentItem(with: item)
        avPlayer.play()
        isActiveSession = true
        updateNowPlayingInfo()

        bitrateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStreamStats()
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func playWithMPV(channel: Channel) {
        stopCurrentBackend()
        activeBackend = .mpv

        // Reset state for MPV playback
        isBuffering = true
        isPlaying = false
        error = nil

        mpvPlayer.updateCacheDuration(bufferDuration)
        mpvPlayer.play(url: channel.streamURL)
        isActiveSession = true
        updateNowPlayingInfo()

        bitrateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStreamStats()
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func stopCurrentBackend() {
        bitrateTimer?.invalidate()
        bitrateTimer = nil

        switch activeBackend {
        case .avPlayer:
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        case .mpv:
            mpvPlayer.stop()
        case .none:
            break
        }
        activeBackend = .none
    }

    func pause() {
        isActiveSession = false
        bitrateTimer?.invalidate()
        bitrateTimer = nil

        switch activeBackend {
        case .avPlayer:
            avPlayer.pause()
        case .mpv:
            // Stop fully for live streams — resume creates a fresh stream
            mpvPlayer.stop()
        case .none:
            break
        }

        isPlaying = false
        isBuffering = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard let channel = currentChannel ?? lastPlayedChannel else { return }
        play(channel: channel)
    }

    func togglePlayPause() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.5 else { return }
        lastToggleTime = now

        if isActiveSession {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        isActiveSession = false
        stopCurrentBackend()
        lastPlayedChannel = currentChannel
        currentChannel = nil
        isPlaying = false
        isBuffering = false
        currentArtwork = nil
        clearNowPlayingInfo()
    }

    func playNext() {
        let list = channels.isEmpty ? ProviderManager.shared.channels : channels
        guard let current = currentChannel ?? lastPlayedChannel,
              let index = list.firstIndex(where: { $0.id == current.id }),
              index + 1 < list.count else { return }
        channels = list
        play(channel: list[index + 1])
    }

    func playPrevious() {
        let list = channels.isEmpty ? ProviderManager.shared.channels : channels
        guard let current = currentChannel ?? lastPlayedChannel,
              let index = list.firstIndex(where: { $0.id == current.id }),
              index > 0 else { return }
        channels = list
        play(channel: list[index - 1])
    }

    func updateBufferDuration(_ duration: TimeInterval) {
        bufferDuration = duration
    }

    // MARK: - Stream Stats

    private func updateStreamStats() {
        guard currentChannel != nil else {
            statusText = ""
            streamBitrateKbps = 0
            return
        }

        // AVPlayer bitrate from access log
        if activeBackend == .avPlayer,
           let event = avPlayer.currentItem?.accessLog()?.events.last {
            let currentKbps = event.observedBitrate / 1000
            if currentKbps > 1, currentKbps > streamBitrateKbps {
                streamBitrateKbps = currentKbps
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
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying || isBuffering) ? 1.0 : 0.0,
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

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }
}
