import AVFoundation
import Foundation

/// Owns the AVAudioEngine that renders PCM produced by VLC (via the
/// VLCAudioCallbackBridge ring buffer) to the device's audio output.
///
/// This is the Swift end of the amem pipeline.  VLC's audio thread
/// writes decoded float32 stereo samples into the bridge's ring
/// buffer; the AVAudioSourceNode's render block pulls from the same
/// buffer on the audio I/O thread.  AdagioStream owns the
/// AVAudioSession exclusively — VLC's audiounit_ios module is never
/// loaded, so VLC can't deactivate the session under us.
///
/// The engine is started once at app init and stays running for the
/// app's lifetime.  Streams come and go (each new VLCMediaPlayer
/// gets its callbacks attached separately), but the engine itself
/// keeps draining the ring buffer continuously.  When VLC is between
/// streams or paused, the ring buffer is empty and the source node
/// outputs silence.
public final class AudioOutput {
    public static let shared = AudioOutput()

    // Pinned format: AVAudioEngine consumes 48kHz stereo float32
    // interleaved, VLC's amem is told to produce exactly this via
    // libvlc_audio_set_format("FL32", 48000, 2).  No resampling or
    // de-interleaving is required between the two sides.
    public static let sampleRate: UInt32 = 48000
    public static let channelCount: UInt32 = 2

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configChangeObserver: NSObjectProtocol?
    private let log = DebugLogger.shared

    /// Whether the caller currently intends audio to be playing.  The
    /// AVAudioEngineConfigurationChange observer only resurrects the engine
    /// while this is true — otherwise a post-stop route change (e.g. CarPlay
    /// disconnect handing the route back to the phone speaker) would restart
    /// the engine and leave it running idle, which reads to the user as "the
    /// session never ended".  Set true by start(), cleared by stop().
    private var intendedToRun = false

    /// Number of consecutive engine.start() failures since the last success.
    /// A sustained streak means the engine is wedged (iOS won't let us bind
    /// the route) — the signature of the unrecoverable CarPlay/Siri wedge.
    private var consecutiveStartFailures = 0

    /// Whether the render engine is actually running.  Callers use this to
    /// distinguish a genuinely-live session from a wedged one (engine stopped
    /// under us by iOS) without relying on higher-level flags.
    public var isRunning: Bool { engine.isRunning }

    /// Consecutive start-failure count, surfaced for the wedge watchdog's
    /// diagnostic snapshot.
    public var startFailureStreak: Int { consecutiveStartFailures }

    private init() {
        // NON-INTERLEAVED (planar) float32.  iOS's AU buses only accept
        // planar formats on input; trying to connect an AVAudioSourceNode
        // configured with interleaved=true crashes inside
        // AUInterfaceBaseV3::SetFormat with an NSException.  The bridge
        // de-interleaves on the C side as it pulls from the ring buffer,
        // so this format mismatch with VLC's FL32 interleaved output is
        // resolved zero-copy on the audio thread.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Double(Self.sampleRate),
                                          channels: AVAudioChannelCount(Self.channelCount),
                                          interleaved: false) else {
            log.log("AudioOutput: failed to construct AVAudioFormat", category: .audioSession)
            return
        }

        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            // REAL-TIME audio I/O thread.  No allocations, no Swift
            // locks, no Obj-C dispatch beyond the C-bridged pull.
            VLCAudioCallbackBridge.reportRenderCall()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftData = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightData = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = ObjCBool(true)
                return noErr
            }
            let requested = Int(frameCount)
            let pulled = VLCAudioCallbackBridge.pullFrames(intoLeft: leftData,
                                                           right: rightData,
                                                           maxFrames: requested)

            if pulled < requested {
                // Underrun (or stream paused / between channels) —
                // zero-fill the tail of each channel so the render
                // block doesn't emit uninitialised memory.
                let zeroCount = requested - pulled
                let zeroBytes = zeroCount * MemoryLayout<Float>.size
                memset(leftData.advanced(by: pulled), 0, zeroBytes)
                memset(rightData.advanced(by: pulled), 0, zeroBytes)
                VLCAudioCallbackBridge.reportUnderrun()
            }
            isSilence.pointee = ObjCBool(pulled == 0)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        // Follow hardware route/format changes.  AVAudioEngine STOPS itself
        // when the output format changes — e.g. CarPlay switching from the
        // Siri/phone voice route (24 kHz mono) back to the media route
        // (48 kHz stereo) after an interruption.  If we don't restart here,
        // the engine that was started against the transient voice route stays
        // dead: VLC keeps filling the ring buffer but nobody drains it, so the
        // stream is "playing" with no audio.  Restart to rebind to the new route.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Only resurrect the engine if the app still intends to play.
            // After a genuine stop (user stop / CarPlay disconnect) the route
            // change must NOT restart us, or the engine runs idle forever.
            guard self.intendedToRun else {
                self.log.log("AudioOutput: configuration changed while idle — not restarting (intendedToRun=false)", category: .audioSession)
                return
            }
            self.log.log("AudioOutput: engine configuration changed (route/format) — restarting engine", category: .audioSession)
            self.performStart()
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// Idempotent.  Checks engine.isRunning directly (rather than a
    /// cached flag) because iOS can stop the engine under us — for
    /// example when the audio session is deactivated during a pause —
    /// without us getting a chance to update local state.  Calling
    /// start() after that path correctly resumes audio output.
    public func start() {
        intendedToRun = true
        performStart()
    }

    /// The actual engine-start work, shared by the public start() and the
    /// configuration-change observer.  Does NOT touch intendedToRun, so the
    /// observer can restart a wanted engine without changing intent.
    private func performStart() {
        guard sourceNode != nil else { return }
        if engine.isRunning { return }
        do {
            try engine.start()
            // Surface the hardware output format the engine actually
            // bound to.  If this doesn't match our source node format
            // (48 kHz stereo float32), AVAudioEngine has inserted an
            // implicit converter and any rate mismatch will show up as
            // pitch artifacts that point straight at the cause.
            let mixerOut = engine.mainMixerNode.outputFormat(forBus: 0)
            let mixerIn  = engine.mainMixerNode.inputFormat(forBus: 0)
            let outputFmt = engine.outputNode.outputFormat(forBus: 0)
            log.log("AudioOutput: engine started, source=Float32 planar \(Self.sampleRate)Hz \(Self.channelCount)ch | mixer.in=\(Int(mixerIn.sampleRate))Hz/\(mixerIn.channelCount)ch | mixer.out=\(Int(mixerOut.sampleRate))Hz/\(mixerOut.channelCount)ch | hwOut=\(Int(outputFmt.sampleRate))Hz/\(outputFmt.channelCount)ch", category: .audioSession)
            if consecutiveStartFailures > 0 {
                log.log("AudioOutput: engine recovered after \(consecutiveStartFailures) consecutive start failure(s)", category: .audioSession)
            }
            consecutiveStartFailures = 0
        } catch {
            consecutiveStartFailures += 1
            log.log("AudioOutput: engine.start() FAILED (streak=\(consecutiveStartFailures)): \(error.localizedDescription)", category: .audioSession)
            // A sustained streak while we still intend to play is the wedge
            // fingerprint — flag it loudly so the next field log makes the
            // unrecoverable state unambiguous.
            if consecutiveStartFailures >= 3 {
                log.log("AudioOutput: WEDGE — engine.start() failed \(consecutiveStartFailures)x in a row while intendedToRun=\(intendedToRun); render pipeline is starved", category: .audioSession)
            }
        }
    }

    public func stop() {
        intendedToRun = false
        guard engine.isRunning else { return }
        engine.stop()
        log.log("AudioOutput: engine stopped", category: .audioSession)
    }
}
