# ADR 0004: Gapless Playback — Design and Deferral Finding

**Status:** Proposed (spike outcome — implementation deferred)

**Full implementation design:** [docs/design/gapless-playback.md](../design/gapless-playback.md)
— this ADR is the decision record (why we defer); the design doc is the
implementation-ready plan (how to build it when prioritized).

---

## Context

The library queue has a ~200–500 ms silent gap between tracks.  The gap is caused
by `startLibraryTrack` → `retirePlayer` tearing down the current `VLCMediaPlayer`
instance and spinning up a fresh one before the next track can start.  The
teardown sequence is:

```
mediaPlayer.stop()          # synchronous VLC drain
mediaPlayer.media = nil     # detach media
VLCAudioCallbackBridge.flushBuffer()  # clear ring buffer tail
retirePlayer(options:)      # background-dispose old instance via DispatchQueue.global
VLCMedia(url:)              # allocate new media
attachAudioCallbacks        # re-attach amem bridge
mediaPlayer.play()          # start buffering → first play_cb
```

Between `flushBuffer()` and the first `adg_audio_play_cb` from the new decoder,
the ring buffer is empty.  The AVAudioSourceNode render block zero-fills those
frames and sets `isSilence = true`.  That silence is the gap.

`d6q.9` investigated `VLCMediaListPlayer` and ruled it out: it owns its own audio
unit and bypasses the amem ring-buffer pipeline entirely, breaking AVAudioSession
ownership, the wedge watchdog, and every interrupt-handling invariant.  `d6q.11`
(this spike) was tasked with evaluating:

1. **Double-buffer approach** — pre-warm a second `VLCMediaPlayer` with amem
   callbacks feeding a second ring buffer; switch the `AVAudioSourceNode` render
   block from buffer A to buffer B at track boundary.
2. **Media-swap-in-place** — reuse the same `VLCMediaPlayer` across tracks by
   swapping media without a full `retirePlayer` cycle.

This spike read the full pipeline implementation before writing any code.

---

## Findings

### 1. The SPSC ring buffer is a global singleton

`VLCAudioCallbackBridge.m` declares a single static ring buffer (`adg_ring_buffer`,
`adg_ring_head`, `adg_ring_tail`) and a single set of static counters.  The amem
callbacks (`adg_audio_play_cb`, `adg_audio_flush_cb`) always write to that one
buffer.  There is no mechanism to direct a second player's callbacks to a second
buffer.

**Implication for double-buffering:** A second `VLCMediaPlayer` with its own amem
callbacks would write into the **same** ring buffer as the first.  The producers
would race — audio from both tracks interleaved in the same ring.  The render
block has no way to know which player produced which frame.  The result would be
audible garbage, not a clean crossfade.

To make double-buffering work, the bridge would need to be refactored from a
global-singleton model to a per-player model.  Each player instance would need its
own ring buffer (or a shared buffer with a tagged-frame mechanism and a switch
signal).  The `AVAudioSourceNode` render block would need to be able to atomically
switch which buffer it drains.  This is a significant re-architecture of the bridge.

### 2. The render block is attached once at engine init

`AudioOutput.init` creates one `AVAudioSourceNode` whose render closure is a
permanent Swift closure captured at construction time.  It calls
`VLCAudioCallbackBridge.pullFramesIntoLeft:right:maxFrames:`, which reads the
global ring.  Changing which buffer the render block reads at runtime would require
either:

- Adding an indirection layer (a `_Atomic` pointer to the active ring) inside the
  bridge, or
- Detaching and re-attaching the `AVAudioSourceNode` (which stops and restarts the
  engine — introducing an engine-restart gap that is likely longer than the current
  decode-startup gap).

Neither path is trivial, and both touch the real-time audio thread.

### 3. retirePlayer's background-dispose is load-bearing

`retirePlayer` exists specifically to move `pthread_join` (VLC internal thread
cleanup) off the main thread.  The code comment documents a known failure mode:
omitting the background dispose caused 0x8BADF00D watchdog kills.  Any approach
that keeps two live `VLCMediaPlayer` instances at the same time keeps two sets of
VLC internal threads alive simultaneously.  The teardown of the "retiring" player
must still go through background dispose.  The double-buffer window (the period
when both players are live) adds concurrency that the current `retirePlayer`
contract does not model.

### 4. Media-swap-in-place shares the retirePlayer risk

Setting `mediaPlayer.media = newMedia` without a `retirePlayer` cycle leaves the
VLC internal threads from the previous stream potentially still running.  The
existing `retirePlayer` comment documents that this is the exact pattern that
triggered watchdog kills.  A media swap without background-dispose is not a safe
shortcut.

Re-attaching amem callbacks to a live player (`attachAudioCallbacksToPlayer:` on an
already-playing instance) is untested.  libvlc's `libvlc_audio_set_callbacks` docs
don't specify the thread-safety contract for a live player, and the current code
only calls it before `mediaPlayer.play()`.

### 5. Threading: two players means two VLC audio threads writing the shared ring

Even if a second ring buffer existed, running two `adg_audio_play_cb` producers
concurrently — each writing into their respective ring — is safe only if the write
path is truly isolated (separate buffer, separate head/tail atomics).  The current
code has none of that partitioning.

### 6. Memory/CPU cost of a second decoder

A second VLC instance holds a full decode pipeline: demuxer threads, codec
decoder thread, resampler, and the amem PCM pipeline.  For local files this is
low CPU; for network streams the caching buffer alone is 3–8 s of decoded audio at
up to ~320 kbps.  The cost is manageable, but it is additive to whatever the first
player is consuming in its final seconds.

### 7. Gap composition: most of the gap is not in VLC startup

`startTrackStream` calls `retirePlayer` which immediately does:
- `old.media = nil` (fast)
- `old.stop()` (synchronous VLC drain — this is the main stall)
- `new VLCMediaPlayer(options:)` (fast)

Then on the background queue: old player dealloc / `pthread_join`.

The ring buffer is flushed before `retirePlayer`, so the render block is already
outputting silence from that point.  The new VLC player then needs to:
1. Network-connect and receive the first HTTP response
2. Demux and decode the first audio frame
3. Fire the first `adg_audio_play_cb`

For local files (downloaded tracks), step 1 is near-instant.  Steps 2–3 are
~50–150 ms typically.  The dominant cost is `old.stop()` blocking on VLC drain,
plus decode startup latency.

For the double-buffer approach to close the gap, the second player would need to
reach step 3 (producing frames) before the first player exhausts the ring.  That
means pre-warming must start several seconds before track end — which requires
accurate end-of-track prediction (available from `Track.duration` / VLC media
length, but unreliable for streams with inaccurate duration metadata).

---

## Decision

**Defer — do NOT implement gapless playback at this time.**

The minimal-risk paths (media swap in place, reusing the player without retire) are
known to risk the 0x8BADF00D watchdog kill — that failure mode is already documented
in `retirePlayer`'s code comment and was hard-won.

The correct path (double-buffering) requires refactoring `VLCAudioCallbackBridge`
from a global-singleton ring to a per-player ring, adding render-block switching
logic on the real-time audio I/O thread, and updating the `AVAudioSourceNode`
render closure architecture in `AudioOutput`.  This is a multi-step architectural
change to the most critical subsystem in the app.

The gap (200–500 ms) is audible but not abnormal for library playback — most
streaming apps have a comparable gap.  The current architecture is stable,
field-proven against CarPlay, interruption, and Siri scenarios.  Destabilising it
for a perceptual improvement that most users won't notice is not the right trade.

---

## What Would Need to Change for a Future Implementation

A future implementation requires four phases, in order:

1. **Per-player ring** — convert the global `adg_ring_*` statics in
   `VLCAudioCallbackBridge` to a heap `AdgRing` struct carried in the `void *`
   opaque user pointer of `libvlc_audio_set_callbacks` (currently NULL).
2. **A/B ring slots in AudioOutput** — two registered rings + a lock-free
   `_Atomic int` active-slot index read in the render block.
3. **GaplessPrewarmController** — prewarm the next track's player into ring B,
   arm when buffered, flip the atomic at `.ended`, retire player A through the
   existing background-dispose path.
4. **Edge-case wiring + feature flag** (`AppSettings.gaplessEnabled`, default off).

The full, implementation-ready design — component sketches, the complete state
machine and edge-case matrix, real-time-safety rules, the session-safety argument,
phased rollout, test plan, risk table, and open questions for the PO — lives in:

**[docs/design/gapless-playback.md](../design/gapless-playback.md)**

This is appropriate for a dedicated follow-on epic once the library queue is
further field-proven.

---

## Consequences

- The ~200–500 ms inter-track gap is accepted for the current release.
- The current `retirePlayer` / amem singleton architecture remains unchanged.
- Radio playback, interruption handling, and the wedge watchdog are unaffected.
- This document provides a concrete implementation plan for when the priority
  justifies the rework.
