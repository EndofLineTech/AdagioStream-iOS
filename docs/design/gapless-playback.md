# Gapless Playback — Implementation Design

**Status:** Design complete, implementation deferred (feature-flagged, ships dark)
**Bead:** beads_mobilemusic-d6q.11
**Decision record:** [ADR-0004](../adr/0004-gapless-playback-design-and-deferral.md)
**Audience:** The engineer who builds this. Self-contained; build straight from it.

All file:line references are against the tree as of this writing. Re-confirm with
`grep` before editing — line numbers drift.

---

## 1. Goals, Non-Goals, Success Criteria

### Goals

- Eliminate (or reduce to imperceptible, target **< 20 ms**) the silent gap between
  consecutive `.library` queue tracks on natural track-end auto-advance (d6q.3).
- Apply to the common case first: **local (downloaded) → local** next-track
  transitions, where the next file is on disk and decode-start latency is lowest.
- Ship behind a feature flag (`AppSettings.gaplessEnabled`, default **off**) so it
  degrades transparently to today's behavior and can be enabled per-build.

### Non-Goals

- Gapless for **radio** (`.radio`). Live streams have no track boundary; the
  prewarm path never activates for radio. Radio is out of scope entirely.
- Gapless across **manual** next/prev gestures. Manual navigation is a deliberate
  user action; a small gap there is acceptable and matches platform norms. (The
  design *may* opportunistically benefit manual-next if buffer B is already warm,
  but this is not a requirement and must never block or delay a manual skip.)
- True sample-accurate gapless with encoder-delay/padding trimming (LAME/iTunSMPB
  gapless metadata). We target *inaudible* gap, not *bit-exact* concatenation.
- Crossfade as a user feature. An optional **short** (≤ 10 ms) equal-power
  crossfade at the switch point is in scope only as a click-suppression mechanism,
  not a music feature.

### Success Criteria

1. With `gaplessEnabled = true`, local→local auto-advance produces no audible gap
   (target < 20 ms of silence at the boundary; verified by ear and by render-block
   underrun counters staying at the steady-state floor across the boundary).
2. **Hard invariant — never worse than today.** With the flag on, if anything in
   the prewarm path fails or is not ready in time, playback falls back to the
   existing teardown-and-restart path. The boundary is then today's ~200–500 ms
   gap, **never** silence longer than that, never a stall, never a crash.
3. With `gaplessEnabled = false`, the code path is byte-for-byte today's behavior.

### Hard Invariants That MUST NOT Regress

These are the load-bearing properties of the audio subsystem. Each has a concrete
anchor in the current code; a regression in any of these is a stop-ship.

| Invariant | Why it matters | Anchor |
|---|---|---|
| **Radio playback unchanged** | Radio is the primary product. | `startStream(for:userInitiated:)` `AudioPlayerService.swift:2170`; prewarm must be gated on `case .library`. |
| **AVAudioSession single-ownership (ADR-0001)** | VLC must never touch the session, or Apple Music auto-resumes on transitions. | amem bridge attach `AudioPlayerService.swift:2291`, `:1961`; ADR-0001. **This is the crux of why two players is safe — see §3.** |
| **Wedge watchdog still fires** | Silent-wedge detection is the only field signal for the unrecoverable CarPlay/Siri state. | `checkAudioHealth()` `AudioPlayerService.swift:379`; samples `renderCallCount` / `playCallbackCount`. |
| **0x8BADF00D / pthread_join dispose safety** | Synchronous `libvlc_media_player_destroy` → `pthread_join` on a stalled socket = 10 s main-thread block = watchdog SIGKILL. | `retirePlayer(options:)` `AudioPlayerService.swift:300`, background dispose `:324`. **Player B's eventual teardown MUST go through this path.** |
| **Interruption recovery (d6q.8)** | Calls/Siri/CarPlay must restore the right source at the right position. | `captureInterruptionSnapshot()` `:997`; `interruptedSource` `:192`. **Prewarm must be cancelled on `.began` and must not corrupt the snapshot.** |
| **Auto-advance correctness (d6q.3)** | The `.ended`→`advance()` decision point owns repeat/shuffle semantics. | `.ended` branch `AudioPlayerService.swift:3156`; `advance()` `:1396`. |

---

## 2. Current Architecture Deep-Dive (with threads)

The pipeline is documented in ADR-0001. Three threads matter:

- **Main thread (MainActor):** `AudioPlayerService` is `@MainActor`
  (`AudioPlayerService.swift:11`). All queue logic, VLC lifecycle calls, and timers
  run here.
- **VLC audio-callback thread:** libvlc's internal audio output thread. It invokes
  the amem callbacks — `adg_audio_play_cb` (`VLCAudioCallbackBridge.m:147`) pushing
  decoded PCM, and `adg_audio_flush_cb` (`:164`). This is the **producer**.
- **Real-time render thread:** CoreAudio's I/O thread driving the
  `AVAudioSourceNode` render block (`AudioOutput.swift:73`). This is the
  **consumer**. No locks, no allocations, no Swift/ObjC dispatch beyond the
  C-bridged pull are permitted here (comment at `AudioOutput.swift:74`).

### 2.1 The single global ring (the blocker)

`VLCAudioCallbackBridge.m` declares **one** ring buffer and **one** set of indices
as file-scope statics:

- `static float adg_ring_buffer[...]` — `VLCAudioCallbackBridge.m:43`
- `static _Atomic uint64_t adg_ring_head` (producer) — `:47`
- `static _Atomic uint64_t adg_ring_tail` (consumer) — `:48`

The ring is a lock-free SPSC design using monotonic 64-bit frame counters masked to
the buffer (`ADG_RING_CAPACITY = 131072` frames ≈ 2.73 s @ 48 kHz, `:39`). Producer
writes with `memory_order_release` on head (`adg_ring_write` `:74`, store at `:113`);
consumer reads with `memory_order_acquire` on head (`adg_ring_read_planar` `:119`,
store tail at `:133`). `adg_ring_flush` snaps tail to head (`:137`).

The play callback **always** writes the global ring:
`adg_audio_play_cb` (`:147`) → `adg_ring_write(...)` (`:153`). The user-data `void *`
argument of `libvlc_audio_set_callbacks` is passed as **`NULL`**
(`VLCAudioCallbackBridge.m:250`) and `data` is ignored in every callback.

**Consequence:** a second `VLCMediaPlayer` with amem callbacks writes into the *same*
ring. Two producers, one buffer → interleaved garbage. The opaque `void *` is the
hook we'll use to fix this (§4.1).

### 2.2 AudioOutput render block + pullFrames

`AudioOutput` (singleton, `AudioOutput.swift:21`) owns one `AVAudioEngine` and one
`AVAudioSourceNode` (`:31`). The node is constructed **once** at init with a
permanent render closure (`:73`) and connected to the main mixer (`:104`–`:105`).
The closure:

1. `VLCAudioCallbackBridge.reportRenderCall()` (`:76`) — wedge-watchdog denominator.
2. Pulls planar L/R via `VLCAudioCallbackBridge.pullFrames(intoLeft:right:maxFrames:)`
   (`:85`), which calls `adg_ring_read_planar` (`VLCAudioCallbackBridge.m:254`→`:119`).
3. Zero-fills the tail on underrun and reports it (`:89`–`:98`).

The engine is started lazily and stays up for app lifetime; the source node outputs
silence when the ring is empty (`AudioOutput.swift:17`–`:19`). `start()` (`:143`)
sets `intendedToRun = true`; `stop()` (`:181`) clears it. The
`AVAudioEngineConfigurationChange` observer (`:114`) rebinds the engine to a new
route only while `intendedToRun` (`:123`).

**Consequence:** the consumer is hard-wired to the global ring. To switch buffers we
need an indirection the render block reads cheaply (§4.2), not a node swap (a node
detach/reattach restarts the engine and *creates* a gap).

### 2.3 retirePlayer / background dispose

`retirePlayer(options:)` (`AudioPlayerService.swift:300`) is the safe VLC-swap
primitive:

- Detaches media (`old.media = nil` `:310`), delegate (`:311`), then `old.stop()`
  (`:312`) — comment explains clearing media first so `stop()` doesn't inherit a
  `poll()` block on a stalled socket.
- Allocates the new player (`:313`–`:319`), sets delegate (`:320`).
- **Disposes the old player on a background utility queue** (`:324`) so the dealloc's
  `libvlc_media_player_destroy` → `pthread_join` can't block main. The header comment
  (`:291`–`:301`) documents that skipping this caused 0x8BADF00D watchdog kills.

**Consequence:** in the gapless design, the *old* player (A) after a successful
crossover must still be retired through this exact background-dispose path. The
window where A and B are both live is new; A's teardown contract is not.

### 2.4 The d6q.3 .ended auto-advance

When VLC reports `.ended` for a `.library` source, `syncState()` calls `advance()`
(`AudioPlayerService.swift:3156`). `advance()` (`:1396`) applies repeat/shuffle and
calls `startLibraryTrack(...)`, which runs the full teardown:
`mediaPlayer.stop()`, `media = nil`, `VLCAudioCallbackBridge.flushBuffer()`
(`:1876`), `retirePlayer(options:)`, attach amem, `play()`. **The flush + decode
startup between flush and the first `play_cb` is the gap.**

`advance()` is the single decision point that knows the *next index* — repeat-one
(`:1406`), repeat-all linear (`:1431`) / shuffle wrap (`:1413`), and `.off` →
`playNextInQueue()` (`:1439`). **The prewarm controller must derive the same "next"
the same way** (§4.3) or it will prewarm the wrong track.

### 2.5 d6q.5 trackElapsed / trackDuration

`trackElapsed` (`AudioPlayerService.swift:95`) and `trackDuration` (`:100`) are
published every timer tick from VLC (`updateNowPlayingInfoForTrack` reads
`mediaPlayer.time` / `media.length`). These are the **trigger signal** for prewarm:
`timeRemaining = trackDuration - trackElapsed`. Duration can be unreliable for some
streams (nil until parsed); the controller must tolerate nil/garbage (§5).

---

## 3. Target Architecture (and why it's session-safe)

Three additions, no removals:

1. **Per-player heap ring** in `VLCAudioCallbackBridge` — each player's amem
   callbacks write into a ring carried by the `void *` opaque user pointer of
   `libvlc_audio_set_callbacks` instead of the global static.
2. **A/B ring slots in `AudioOutput`** — the render block reads a `_Atomic` active-
   slot index and pulls from that slot's ring, lock-free.
3. **`GaplessPrewarmController`** in `AudioPlayerService` — owns the second player
   (B), decides when to prewarm, when to arm, performs the atomic crossover, and
   retires A through the existing background-dispose path.

```
                 ┌─────────────────── AudioPlayerService (MainActor) ──────────────────┐
                 │  playerA (current)        GaplessPrewarmController                   │
                 │      │                         │  playerB (prewarm, may be nil)      │
                 │      │ attach(ringA)           │      │ attach(ringB)                │
                 ▼      ▼                         ▼      ▼                              │
   VLC audio thread A ──► ringA  (heap)     VLC audio thread B ──► ringB (heap)         │
                 └──────────┬──────────────────────────┬───────────────────────────────┘
                            │     AudioOutput owns ringA + ringB; activeSlot ∈ {A,B}
                            ▼
                 AVAudioSourceNode render block (real-time thread):
                   slot = atomic_load(activeSlot);  pull from rings[slot]
```

### Why two VLC players is SESSION-SAFE (the crux)

ADR-0001's entire safety argument is that the app owns `AVAudioSession` and VLC's
`audiounit_ios` module — the one that calls
`setActive(false, .notifyOthersOnDeactivation)` — is **never loaded**, because every
player is pinned to **amem** via `attachAudioCallbacks` before `play()`
(`AudioPlayerService.swift:2291`, `:1961`; `libvlc_audio_set_callbacks`
`VLCAudioCallbackBridge.m:244`).

Both player A and player B are **amem-only**. Neither ever instantiates
`audiounit_ios`; neither ever calls `setActive` on the session. The
`AVAudioSession` and the single `AVAudioEngine` are owned by the app
(`AudioOutput`), entirely independent of how many VLC decoders are feeding rings.
Adding player B adds a **second PCM producer**, not a second session client. The
session-ownership invariant is therefore structurally preserved: there is exactly
one session owner (the app) regardless of decoder count. This is the property that
makes double-buffering viable here where `VLCMediaListPlayer` (which owns its own
audio unit) is not.

The wedge watchdog also remains valid: it samples `renderCallCount` (still one
render block) and `playCallbackCount` (now summed across producers — see §4.1 note
on global counters).

---

## 4. Component-Level Design

### 4.1 Per-player ring refactor (`VLCAudioCallbackBridge.{h,m}`)

Replace the file-scope ring statics with a heap-allocated struct, one per player.

```c
// New: one ring per player, carried in libvlc's opaque user pointer.
typedef struct AdgRing {
    float            buffer[ADG_RING_CAPACITY * ADG_FRAME_FLOATS];
    _Atomic uint64_t head;   // producer (VLC audio thread for THIS player)
    _Atomic uint64_t tail;   // consumer (render thread, when this is the active slot)
} AdgRing;
```

- `attachAudioCallbacksToPlayer:` (`VLCAudioCallbackBridge.m:227`) allocates an
  `AdgRing` (zeroed), and passes it as the **opaque** argument currently `NULL` at
  `:250`. Return the ring pointer to Swift (new out-param or a returned handle) so
  `AudioOutput` can register it as slot A or B.
- `adg_audio_play_cb` (`:147`) casts `data` → `AdgRing *` and calls
  `adg_ring_write(ring, samples, count)`. `adg_audio_flush_cb` (`:164`) flushes that
  ring. The `adg_ring_*` functions gain an `AdgRing *` first parameter; the bodies
  are otherwise unchanged from `:74`/`:119`/`:137`.
- Free contract: a ring is freed when its player is retired. **Ownership rule:** the
  ring outlives the player's last callback. Free only after the player is fully
  disposed (the background-dispose closure at `:324` is the natural place — extend it
  to also `free(ring)` after `old` deallocs). Never free a ring that is the active
  slot. Document this lifetime in the header.

**Real-time safety rules (unchanged, restated):** the ring stays lock-free SPSC.
Producer (VLC thread) owns head; consumer (render thread) owns tail; the only
cross-thread coordination is the acquire/release on head/tail. No allocation or free
on either hot path — allocation happens at attach (main thread), free happens at
dispose (utility queue).

**Counters note:** the diagnostic counters (`adg_play_count` etc., `:50`–`:57`) stay
global (process-wide) — they're aggregate health signals and the wedge watchdog
reads them as deltas. Keep them global so the watchdog logic at
`AudioPlayerService.swift:379` is untouched. (Per-player counters are a possible
later refinement; not required.)

### 4.2 AudioOutput A/B + atomic crossover (`AudioOutput.swift`)

`AudioOutput` gains two registered ring slots and an atomic active index. Because the
render block is C-bridged, the slot indirection lives in the **bridge** (the render
block already calls into ObjC), exposed to Swift as a small API:

```c
// VLCAudioCallbackBridge — slot management (called from main thread):
+ (void)setActiveRing:(AdgRing *)ring forSlot:(int)slot;   // slot 0=A, 1=B
+ (void)setActiveSlot:(int)slot;            // atomic store, the crossover flip
// Render-thread pull now reads the active slot:
+ (NSInteger)pullFramesIntoLeft:(float*)l right:(float*)r maxFrames:(NSInteger)n;
```

Internally the bridge holds `static AdgRing *adg_slots[2];` and
`static _Atomic int adg_active_slot;`. `pullFramesIntoLeft:` (currently `:254`) does:

```c
int slot = atomic_load_explicit(&adg_active_slot, memory_order_acquire);
AdgRing *r = adg_slots[slot];
if (!r) return 0;                      // nothing active → silence (today's behavior)
return adg_ring_read_planar(r, left, right, maxFrames);
```

- The render block in `AudioOutput.swift:73` is **unchanged** — it still calls
  `pullFrames(...)`; the slot read is hidden in the bridge. This keeps the
  hard-won render closure untouched.
- **The atomic flip is the only cross-thread coordination for the crossover.** Main
  thread does `setActiveSlot(1)`; the render thread picks it up on its next call
  with an acquire load. One writer (main), one reader (render) → a plain
  `_Atomic int` store/load is sufficient; no fence beyond acquire/release.

**Optional click suppression (equal-power micro-crossfade):** a hard buffer flip can
click if A and B aren't at a zero-crossing. To suppress, the bridge can, for the
first `N` frames after a flip (N ≈ 480 = 10 ms @ 48 kHz), pull from *both* rings and
mix with an equal-power ramp (gainA = cos(θ), gainB = sin(θ)). This requires keeping
A's ring readable for those N frames (don't flush/free A until the fade completes).
**Keep this optional and behind the same flag**; ship the hard flip first, add the
fade only if clicks are audible in testing. The fade math is allocation-free (a
precomputed ramp table) and runs on the render thread within the no-alloc rule.

### 4.3 GaplessPrewarmController (`AudioPlayerService`)

A new type (own file `AdagioStream/Services/Audio/GaplessPrewarmController.swift`),
driven from the MainActor. It does **not** own the session or the engine; it owns
only player B and ring B's lifecycle, and it calls back into `AudioPlayerService` for
the crossover commit.

```swift
@MainActor
final class GaplessPrewarmController {
    enum State {
        case idle                      // no prewarm in flight
        case prewarming(index: Int)    // player B created, decoding into ring B
        case armed(index: Int)         // ring B has >= armThreshold frames buffered
    }
    private(set) var state: State = .idle
    private var playerB: VLCMediaPlayer?
    private var ringB: OpaquePointer?  // AdgRing*, registered as slot 1

    // Tunables
    let prewarmLeadSeconds: Double = 3.0     // start B when timeRemaining <= this
    let armThresholdFrames: Int = 24_000     // ~0.5s @ 48kHz before we trust B
}
```

**Lifecycle, all on MainActor:**

1. **Decide & prewarm.** On each timer tick, `AudioPlayerService` computes
   `timeRemaining = trackDuration - trackElapsed` (from `:95`/`:100`). If
   `gaplessEnabled`, source is `.library`, `state == .idle`, duration is known and
   `timeRemaining <= prewarmLeadSeconds`, ask the controller to prewarm **the index
   `advance()` would pick** (see §4.3.1). Controller:
   - Resolves the next track's URL via the *same* `resolvePlaybackURL(trackID:api:)`
     used by `startLibraryTrack` (`AudioPlayerService.swift:1814`) — preserves
     local-first (l31.3).
   - Allocates ring B, creates player B with the **same instance options** as a
     normal track (`startTrackStream` uses `--network-caching=<cacheMs>`,
     `:1936`-area), attaches amem to player B with ring B as the opaque pointer,
     `play()`s B, registers ring B as slot 1. **Player B's audio flows into ring B
     and nowhere else; activeSlot is still A, so B is inaudible.**
   - `state = .prewarming(index:)`.

2. **Arm.** When `bufferedFrames(ringB) >= armThresholdFrames`, `state = .armed`.
   (Bridge exposes a per-ring `bufferedFrames(ring)` query.)

3. **Crossover.** When player A reports `.ended` for the `.library` track
   (`syncState` `.ended` branch `:3156`), **if** `state == .armed(index)` and that
   index still matches what `advance()` would pick:
   - `VLCAudioCallbackBridge.setActiveSlot(1)` — the atomic flip. Audio is now B.
   - Update `AudioPlayerService` published state to reflect B as current: set
     `currentQueueIndex`, `playbackSource = .library(queue, index)`, `currentTrack`,
     reset scrobble guard, fire now-playing scrobble, update remote commands —
     i.e. the same state updates `startLibraryTrack` performs (`:1828`-area), but
     **without** tearing down/recreating a player, because B is already playing.
   - **Retire A** through the existing background-dispose path: hand player A to
     `retirePlayer`-equivalent logic so its `pthread_join` runs on the utility queue
     (`:324`). Free ring A after A deallocs and after any crossfade window.
   - Promote B to be the new primary `mediaPlayer`; relabel ring B as slot 0 for the
     next cycle (swap slot registration so the next prewarm uses the now-free slot).
   - `state = .idle`.

   **If** `state != .armed` at `.ended` (B not ready, or no prewarm): do nothing
   special — fall straight through to today's `advance()` → `startLibraryTrack` path.
   This is the transparent fallback (success criterion #2).

#### 4.3.1 Deriving "next" identically to advance()

`advance()` (`:1396`) is the authority. To avoid divergence, **extract the
index-selection logic** into a pure function the controller can call without side
effects:

```swift
// Pure: given current source + repeat/shuffle state, return the index advance()
// WOULD play next, or nil if advance() would stop (queue end, repeat .off).
func nextAutoAdvanceIndex() -> Int?
```

`advance()` is then refactored to compute the index via this function and act on it.
The controller calls the same function to know what to prewarm. **If the function
returns nil (queue would end), do not prewarm.** Repeat-one returns the *same* index
(prewarm the same track — that is correct and gapless-loops it).

---

## 5. State Machine + Every Edge Case

`State`: `idle → prewarming → armed → (crossover) → idle`, with cancel edges back to
`idle` from any state.

| Event | Required behavior |
|---|---|
| **Tick, timeRemaining ≤ lead, idle, duration known** | Prewarm `nextAutoAdvanceIndex()`. If it returns nil → stay idle (queue end). |
| **Manual next/prev during prewarm/armed** | **Cancel B** (stop, dispose via background path, free ring B, slot stays A), then run the normal manual path (`playNextInQueue`/`playPreviousInQueue`). Never let a warmed B for index N hijack a manual jump to a different index. If the manual target equals B's index *and* B is armed, an optimization may flip to B instead — but default to cancel-and-restart for simplicity in phase 3. |
| **Seek during prewarm/armed** | Cancel B (the boundary moved; B's lead-time assumption is void). Re-prewarm later when timeRemaining re-enters the window. |
| **Repeat-one** | `nextAutoAdvanceIndex()` returns the same index → prewarm the same track → gapless loop. Correct. |
| **Repeat-all wrap** | `nextAutoAdvanceIndex()` returns the wrapped index (0 or reshuffled). Prewarm that. Matches `advance()` `:1412`-area. |
| **Shuffle next** | `nextAutoAdvanceIndex()` consults shuffle order. **Caveat:** prewarm must not *advance the shuffle cursor* — it only *peeks*. The cursor advances at crossover (when `advance()`'s state mutation runs). If the user toggles shuffle between prewarm and `.ended`, cancel B (peeked index may be stale). |
| **Queue end (no repeat)** | `nextAutoAdvanceIndex()` returns nil → never prewarm → `.ended` runs today's stop path. |
| **Interruption `.began` during prewarm/armed** | **Cancel B immediately** (stop, background-dispose, free ring B, slot A). Do **not** let prewarm corrupt `captureInterruptionSnapshot()` (`:997`) — snapshot reads `playbackSource`/`mediaPlayer.time` of player **A**, which is untouched by B. Verify the snapshot still reflects A. d6q.8 restore path is unchanged. |
| **Error starting player B** | If B fails to open/decode (`.error`/`.stopped` on B, or arm threshold never reached before `.ended`), **fall back**: at `.ended`, B is not armed → today's `advance()` path. Log it. No user-visible failure beyond today's gap. |
| **Track shorter than prewarm window** | If `trackDuration < prewarmLeadSeconds` (or duration unknown), the tick trigger may fire immediately at track start or never. Guard: only prewarm once `trackElapsed > 0` and `timeRemaining` is in `(0, lead]`. For ultra-short tracks, prewarm may not complete in time → fallback. Acceptable. |
| **Rapid skipping** | Each manual skip cancels any in-flight B before starting the new track. The background-dispose path bounds teardown cost off-main. Ensure cancel is idempotent and that two disposes of the same B can't race (nil out `playerB` on cancel). |
| **Local-first vs streamed next** | URL resolution goes through `resolvePlaybackURL` (`:1814`) so a downloaded next track uses `file://` (fast decode-start, best gapless) and a streamed next track uses the Navidrome URL (network caching applies; arm threshold protects against starting before B has audio). No special-casing needed beyond honoring the arm threshold. |
| **Duration unreliable (nil/garbage)** | If `trackDuration` is nil or `timeRemaining` computes negative/absurd, **do not prewarm** this track. Fallback to today's gap. |

---

## 6. Memory / CPU Cost

- **Memory:** each `AdgRing` is `131072 × 2 × 4 bytes ≈ 1.0 MiB`. Two rings ≈ 2 MiB
  (vs ~1 MiB today). Player B holds a second VLC decode pipeline (demux + decoder +
  resampler + network cache). For a streamed next track the cache is the bulk:
  `network-caching` × bitrate (e.g. 3 s × 320 kbps ≈ 120 KB). Bounded and transient.
- **CPU:** a second decoder runs only for ~`prewarmLeadSeconds` (≈ 3 s) per track
  boundary, overlapping the tail of A. Local-file decode is cheap; the overlap is
  brief. Steady-state (mid-track) cost is unchanged — B does not exist then.
- **Crossfade (optional):** the micro-crossfade pulls from two rings for ≤ 10 ms per
  boundary — negligible.

Net: a small, transient overhead localized to track boundaries. No steady-state cost.

---

## 7. Failure / Fallback + Feature Flag

- **Feature flag:** add `AppSettings.gaplessEnabled: Bool` (default **false**) next to
  `repeatMode`/`shuffleEnabled` (`AppSettings.swift:192`–`:194`; constructor default at
  `:214`-area). Plumb to `AudioPlayerService` like `applyQueuePreferences` does for
  repeat/shuffle. Ships dark.
- **Transparent degradation:** every prewarm/arm/crossover step has a guarded
  fallback to today's `advance()` → `startLibraryTrack` path. The flag-off path is
  literally today's code (the controller is never consulted). With the flag on, any
  not-ready/error condition lands on the same fallback. **Floor guarantee:** the
  boundary is never worse than today's ~200–500 ms gap.
- **Kill switch:** because it's an `AppSettings` bool, it can be force-disabled per
  build (or via a remote/config gate if one exists later) without a code change.

---

## 8. Phased Rollout (each phase independently shippable + testable)

**Phase 1 — Per-player ring (behavior-neutral).** Refactor
`VLCAudioCallbackBridge.{h,m}` to the `AdgRing` struct carried in the opaque pointer.
Single player still; `AudioOutput` registers that one ring as slot A and never flips.
**No behavior change** — verified by existing radio + library playback being
identical. This de-risks the hardest C change in isolation. Ship it; bake it.

**Phase 2 — AudioOutput A/B plumbing (still single-player runtime).** Add slot
registration, `adg_active_slot`, `setActiveSlot`, and the slot read in
`pullFramesIntoLeft:`. Active slot stays A in production. Unit-test the A/B switch in
isolation (write known PCM to ring A and ring B, flip the atomic, assert the render
pull reads the right ring). No user-facing change yet.

**Phase 3 — Prewarm controller behind the flag.** Add
`GaplessPrewarmController`, the `nextAutoAdvanceIndex()` extraction, the tick trigger,
the crossover commit, and `AppSettings.gaplessEnabled`. Default off. Enable in dev
builds for device validation; flip default on only after field validation.

---

## 9. Test Plan

### Unit tests (AdagioStreamTests/Services)

- **Per-player ring routing (Phase 1):** attach two rings, write distinct PCM via
  each `adg_ring_write`, assert each ring reads back only its own samples (no
  cross-contamination). Confirms the opaque-pointer routing.
- **SPSC ring correctness (regression):** existing ring semantics — wrap, overflow
  drop (`adg_dropped_frames` path `VLCAudioCallbackBridge.m:81`-area), flush — still
  hold per-ring. Port any existing ring tests to the struct form.
- **A/B switch (Phase 2):** fill ring A and ring B with constant but distinct values;
  `setActiveSlot(0)` → pull returns A's value; `setActiveSlot(1)` → pull returns B's
  value; verify the switch takes effect on the next pull (acquire semantics).
- **Prewarm state machine as pure logic (Phase 3):** drive a stubbed controller (no
  real VLC) through every §5 row — idle→prewarming→armed→crossover, and every cancel
  edge (manual next, seek, interruption, shuffle-toggle, queue-end-nil,
  duration-nil, short-track). Assert state transitions and that `nextAutoAdvanceIndex`
  matches `advance()`'s choice for repeat-off/all/one and shuffle. **This is the bulk
  of the value: the edge cases are pure logic and must be exhaustively covered.**
- **nextAutoAdvanceIndex parity:** property-style test that for a matrix of
  (repeatMode × shuffle × index) the function's result equals the index `advance()`
  actually plays (drive `advance()` with a stubbed `startLibraryTrack` capturing the
  index).

### Manual / device validation

- **Actual gapless:** local→local auto-advance with flag on — no audible gap; render
  underrun counter (`renderUnderrunCount`) does not spike at the boundary.
- **Radio unaffected:** radio playback, channel change, time-shift buffer — identical
  with flag on and off. (Prewarm must never engage for `.radio`.)
- **Interruption during prewarm:** trigger a call/Siri while B is prewarming/armed;
  confirm B is cancelled, A's snapshot (d6q.8) is intact, and resume restores A at
  the right position.
- **Skip during prewarm:** manual next while B warming for a *different* index →
  correct track plays, no stale-B hijack.
- **Wedge watchdog still fires:** force a wedge (engine stopped under us) and confirm
  `checkAudioHealth()` (`:379`) still logs WEDGE — the single render block and global
  counters are unchanged.
- **Streamed next track:** next track not downloaded → arm threshold prevents a
  premature flip into silence; gap is no worse than today if B can't warm in time.
- **Rapid skipping stress:** mash next/prev; no crash, no leak (rings freed), no
  main-thread stall (dispose stays off-main).

---

## 10. Risks + Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Two producers race the wrong ring | High | Per-player ring via opaque pointer (§4.1); Phase-1 unit test for routing isolation. |
| Render block reads a freed ring at crossover | High | Free ring A only after A is disposed *and* after the crossfade window; never free the active slot. Lifetime rule documented in header. |
| pthread_join stall reintroduced by B's teardown | High | B is always retired through the existing background-dispose path (`:324`); never synchronously destroyed on main. |
| Session ownership regressed by 2nd player | High | Both players amem-only; neither loads `audiounit_ios`; one session owner (the app). Asserted in §3 and by the "radio/Apple-Music-no-resume" manual test. |
| Prewarm corrupts interruption snapshot (d6q.8) | High | Cancel B on `.began`; snapshot reads player A state only. Device test for interruption-during-prewarm. |
| Shuffle cursor advanced twice (peek + crossover) | Med | `nextAutoAdvanceIndex` only *peeks*; cursor advances solely in `advance()` at crossover. Cancel B if shuffle toggled mid-prewarm. |
| Click at hard buffer flip | Med | Optional equal-power micro-crossfade (§4.2), behind the flag; ship hard flip first, add fade if audible. |
| Duration metadata unreliable triggers bad prewarm | Med | Only prewarm with known, sane duration and `timeRemaining ∈ (0, lead]`; else fallback. |
| Extra memory/CPU on low-end devices | Low | ~1 MiB extra ring + transient decoder for ~3 s/boundary; flag-off removes it entirely. |

---

## Open Questions (for the PO)

1. **Default lead time / arm threshold.** Proposed `prewarmLeadSeconds = 3.0`,
   `armThresholdFrames ≈ 0.5 s`. Tune on-device. Is 3 s acceptable extra decode
   overlap on the oldest supported hardware?
2. **Manual-next opportunistic gapless?** Default is cancel-and-restart on manual
   skip (simple, safe). Worth the extra complexity to flip to an already-armed B when
   the manual target matches B's index? (Lean: no, phase 3.1 at most.)
3. **Crossfade: ship at all?** Recommend hard flip first; add the ≤10 ms equal-power
   fade only if clicks are heard. Does the PO want the fade in scope from the start?
4. **Streamed-next gapless expectations.** Gapless is reliable for local→local. For
   streamed next tracks it's best-effort (arm threshold + network caching). Is
   "gapless for downloaded albums, best-effort for streamed" an acceptable product
   statement?
5. **Where does the flag live in UI?** Hidden `AppSettings` bool only (dev/QA flip),
   or a user-facing Settings toggle once validated?
6. **tvOS.** Same `AudioPlayerService` runs on tvOS-VLC. Is gapless in scope for
   tvOS in the first release, or iOS-only until field-proven?
