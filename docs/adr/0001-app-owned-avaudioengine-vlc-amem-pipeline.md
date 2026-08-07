# ADR 0001: App-owned AVAudioEngine with libvlc amem PCM callbacks

**Status:** Accepted

---

## Context

Adagio Stream uses VLCKit (via VLCKitSPM) as its media engine because it handles
the codec variety required by IPTV and Subsonic sources — arbitrary HLS, MPEG-TS,
AAC, MP3, Opus, and container formats that AVPlayer cannot decode.

VLCKit's default iOS audio output module is `audiounit_ios`.  That module owns the
`AVAudioSession` directly: it calls `setActive(true)` when playback starts and
— critically — `setActive(false, .notifyOthersOnDeactivation)` when
`mediaPlayer.stop()` is called.  This deactivation triggers the `otherAudioResumed`
callback in competing apps (most visibly Apple Music and system alerts), and it does
so unconditionally on every channel change, every stop, and every player tear-down
cycle.  The root cause is that `audiounit_ios` owns the session; the app does not.

A secondary consequence: the audiounit_ios module may grab the audio route during
CarPlay interruption recovery in a way that cannot be undone from Swift without
restarting the entire VLC player, compounding the interruption-handling complexity.

## Decision

Replace VLC's `audiounit_ios` output module with libvlc's PCM-callback (`amem`)
output module.  The app interposes an Objective-C bridge (`VLCAudioCallbackBridge`)
that:

1. Registers `libvlc_audio_set_callbacks` on each `VLCMediaPlayer` instance,
   directing VLC's audio thread to push decoded samples into a lock-free
   single-producer single-consumer ring buffer (131,072 stereo frames ≈ 2.73 s
   at 48 kHz).
2. Pins the decoder output to S16N (interleaved int16) via
   `libvlc_audio_set_format` — VLC 3.x's amem module hardcodes S16N regardless
   of the requested format (a known upstream limitation noted in
   `modules/audio_output/amem.c`).  The bridge converts int16 → float32 on the
   producer side.
3. Exposes a `pullFrames(intoLeft:right:maxFrames:)` method that de-interleaves
   float32 samples from the ring buffer into the planar format required by iOS
   Audio Unit buses.

On the Swift side, `AudioOutput` (see `AdagioStream/Services/Audio/AudioOutput.swift`)
owns a single `AVAudioEngine` with an `AVAudioSourceNode` whose render block calls
`VLCAudioCallbackBridge.pullFrames` on the real-time audio I/O thread.  The engine
is started once at app init and remains running for the app's lifetime; the source
node outputs silence when no frames are buffered.

`AVAudioSession` is configured by the app in `AudioPlayerService.configureAudioSession()`
with `.playback` category and `longFormAudio` policy.  VLC never touches the session.

## Consequences

**Positive:**
- The app owns the `AVAudioSession` exclusively.  VLC cannot deactivate it during
  channel changes, interruption recovery, or player tear-down.
- Apple Music no longer auto-resumes when Adagio Stream changes channels.
- Interruption handling is fully under app control: the short-interruption path
  keeps VLC alive without restarting the engine; the long-interruption fallback
  does a controlled session deactivate/reactivate.
- `AVAudioEngineConfigurationChange` notifications allow the engine to rebind to
  a new hardware route (e.g., after a CarPlay Siri voice route transitions back
  to the media route at 48 kHz stereo) without restarting the VLC player.

**Negative / trade-offs:**
- The ObjC bridge adds ~300 lines of C/Objective-C that must be maintained in
  step with VLCKit API changes.
- VLC 3.x amem hardcodes S16N output, requiring an int16→float32 conversion step
  on every audio callback.  If a future VLC version changes this, the bridge
  conversion logic must be updated.
- The ring buffer is sized for ~2.73 s of headroom; network stalls longer than
  that will drain the buffer and cause an audible gap, the same as any other
  buffering scenario.
- Testing the full pipeline requires real audio hardware or a simulator with audio
  routing; unit tests cover the ring buffer logic but not the AVAudioEngine path.

**Files:**
- `AdagioStream/Services/Audio/VLCAudioCallbackBridge.h`
- `AdagioStream/Services/Audio/VLCAudioCallbackBridge.m`
- `AdagioStream/Services/Audio/AudioOutput.swift`
- `AdagioStream/Services/AudioPlayerService.swift` (session ownership)
