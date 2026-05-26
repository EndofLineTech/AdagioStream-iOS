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
    private var isRunning = false
    private let log = DebugLogger.shared

    private init() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Double(Self.sampleRate),
                                          channels: AVAudioChannelCount(Self.channelCount),
                                          interleaved: true) else {
            log.log("AudioOutput: failed to construct AVAudioFormat", category: .audioSession)
            return
        }

        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            // REAL-TIME audio I/O thread.  No allocations, no Swift
            // locks, no Obj-C dispatch beyond the C-bridged pullFrames.
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let mData = abl[0].mData else {
                isSilence.pointee = ObjCBool(true)
                return noErr
            }
            let dest = mData.assumingMemoryBound(to: Float.self)
            let requested = Int(frameCount)
            let pulled = VLCAudioCallbackBridge.pullFrames(into: dest, maxFrames: requested)

            if pulled < requested {
                // Underrun (or stream paused / between channels) —
                // zero-fill the rest so the render block doesn't
                // emit uninitialised memory.  Two channels interleaved,
                // four bytes per sample.
                let writtenSamples = pulled * Int(Self.channelCount)
                let remainingSamples = (requested - pulled) * Int(Self.channelCount)
                let byteOffset = writtenSamples * MemoryLayout<Float>.size
                let byteLength = remainingSamples * MemoryLayout<Float>.size
                memset(mData.advanced(by: byteOffset), 0, byteLength)
            }
            isSilence.pointee = ObjCBool(pulled == 0)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    public func start() {
        guard !isRunning, sourceNode != nil else { return }
        do {
            try engine.start()
            isRunning = true
            log.log("AudioOutput: engine started, format=FL32 \(Self.sampleRate)Hz \(Self.channelCount)ch", category: .audioSession)
        } catch {
            log.log("AudioOutput: engine.start() FAILED: \(error.localizedDescription)", category: .audioSession)
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
        log.log("AudioOutput: engine stopped", category: .audioSession)
    }
}
