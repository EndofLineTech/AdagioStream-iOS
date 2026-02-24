import Foundation
import Libmpv

/// Lightweight wrapper around libmpv for audio-only playback of raw MPEG-TS
/// and other formats that AVPlayer cannot handle natively.
final class MPVAudioPlayer: @unchecked Sendable {

    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case error(String)
    }

    var onStateChange: (@Sendable (State) -> Void)?
    var onBitrateUpdate: (@Sendable (Double) -> Void)?  // kbps

    private var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "com.adagiostream.mpv.events")
    private var isRunning = false

    init() {
        setupMPV()
    }

    deinit {
        shutdown()
    }

    // MARK: - Setup

    private func setupMPV() {
        mpv = mpv_create()
        guard let mpv else { return }

        // Audio-only — no video output, auto-detect audio output
        mpv_set_option_string(mpv, "vo", "null")

        // Caching for live streams
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "10")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "32MiB")
        mpv_set_option_string(mpv, "demuxer-readahead-secs", "10")

        // User agent
        mpv_set_option_string(mpv, "user-agent", "AdagioStream/1.0")

        // Keep the player alive on EOF (useful for stream reconnection)
        mpv_set_option_string(mpv, "keep-open", "yes")
        mpv_set_option_string(mpv, "idle", "yes")

        let err = mpv_initialize(mpv)
        guard err >= 0 else {
            let msg = String(cString: mpv_error_string(err))
            onStateChange?(.error("MPV init failed: \(msg)"))
            return
        }

        // Observe properties we care about
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "idle-active", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)

        // Set up wakeup callback
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let player = Unmanaged<MPVAudioPlayer>.fromOpaque(ctx).takeUnretainedValue()
            player.drainEvents()
        }, pointer)

        isRunning = true
    }

    // MARK: - Playback Control

    func play(url: URL) {
        guard let mpv else { return }
        onStateChange?(.loading)
        let urlString = url.absoluteString
        urlString.withCString { cURL in
            var args: [UnsafePointer<CChar>?] = []
            "loadfile".withCString { cCmd in
                args = [cCmd, cURL, nil]
                mpv_command(mpv, &args)
            }
        }
    }

    func pause() {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "pause", "yes")
    }

    func resume() {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "pause", "no")
    }

    func stop() {
        guard let mpv else { return }
        mpv_command_string(mpv, "stop")
        onStateChange?(.idle)
    }

    func updateCacheDuration(_ seconds: TimeInterval) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "cache-secs", "\(Int(seconds))")
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "\(Int(seconds))")
    }

    func shutdown() {
        guard let mpv, isRunning else { return }
        isRunning = false
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    // MARK: - Event Handling

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv, self.isRunning else { return }
            while true {
                let event = mpv_wait_event(mpv, 0)!
                let eventID = event.pointee.event_id
                if eventID == MPV_EVENT_NONE { break }
                self.handleEvent(event.pointee)
            }
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            onStateChange?(.playing)

        case MPV_EVENT_PLAYBACK_RESTART:
            // Playback started or resumed after seeking/buffering
            onStateChange?(.playing)
            pollBitrate()

        case MPV_EVENT_END_FILE:
            if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                let reason = data.pointee.reason
                if reason == MPV_END_FILE_REASON_ERROR {
                    let code = data.pointee.error
                    let msg = String(cString: mpv_error_string(code))
                    onStateChange?(.error("Playback error: \(msg)"))
                } else {
                    onStateChange?(.idle)
                }
            }

        case MPV_EVENT_PROPERTY_CHANGE:
            guard let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { break }
            let name = String(cString: prop.pointee.name)
            handlePropertyChange(name: name, prop: prop.pointee)

        default:
            break
        }
    }

    private func handlePropertyChange(name: String, prop: mpv_event_property) {
        switch name {
        case "pause":
            guard prop.format == MPV_FORMAT_FLAG,
                  let data = prop.data?.assumingMemoryBound(to: Int32.self) else { break }
            let isPaused = data.pointee != 0
            if isPaused {
                onStateChange?(.paused)
            } else {
                onStateChange?(.playing)
            }
        default:
            break
        }
    }

    private func pollBitrate() {
        guard let mpv else { return }
        var bitrate: Double = 0
        let err = mpv_get_property(mpv, "demuxer-cache-state", MPV_FORMAT_NONE, nil)
        if err >= 0 {
            // Try audio bitrate from the demuxer
            var audioBitrate: Int64 = 0
            if mpv_get_property(mpv, "audio-bitrate", MPV_FORMAT_INT64, &audioBitrate) >= 0 {
                bitrate = Double(audioBitrate) / 1000.0  // bps → kbps
            }
        }
        if bitrate > 0 {
            onBitrateUpdate?(bitrate)
        }
    }
}
