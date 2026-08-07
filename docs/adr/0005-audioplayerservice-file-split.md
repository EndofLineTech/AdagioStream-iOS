# ADR 0005: AudioPlayerService File Split (Mechanical, MARK-Boundary)

**Status:** Accepted

---

## Context

`AudioPlayerService.swift` had grown to 3,662 lines across 24 `MARK` sections
in a single file — the reliability heart of the app (VLC lifecycle,
`AVAudioSession` ownership, interruption handling, queue/shuffle/repeat,
reconnect, Now Playing publishing) with no file-level structure to match its
24 concerns. The 2026-07-08 code-redundancy team review (finding #13, Architect)
flagged this: the test suite is already split by concern (`ScrobbleTests`,
`NowPlayingQueueUITests`, `ShuffleRepeatTests`, `InterruptionRecoveryTests`,
…) but the source never got the equivalent split.

The Engineer's counter-position (pre-acknowledged by the Architect in the
same review): this is a large, no-behavior-change diff, and at review time
three P1 CarPlay interruption bugs (`46u`, `lfn`, `of1`) were still awaiting
field validation against this exact file. Landing a mechanical split
mid-hotfix-stream would conflict with those in-flight fixes and complicate
their verification.

**Team lean:** defer the split until `46u`/`lfn`/`of1` are field-confirmed
and closed, then land it as a standalone commit before the next feature
touches this file. `beads_mobilemusic-t96.14` was filed with explicit `dep
add` edges on all three bugs, so it could not be claimed as ready until they
closed.

## Decision

Once `46u`, `lfn`, and `of1` were field-confirmed closed, split
`AudioPlayerService.swift` mechanically along its existing `MARK` boundaries
in one atomic commit (`767bc73`):

- **Root file** (`AudioPlayerService.swift`, 1,379 lines) — the class
  declaration, all 81 stored properties, `init`, and the core hub methods:
  `play`, `startStream`, `pause`, `resume`, `stop`, `syncState`.
- **`AudioPlayerService+Interruption.swift`** (661 lines) — wedge watchdog,
  `AVAudioSession` configuration, interruption/route-change handlers,
  interruption capture/restore, `assertSessionOwnership`.
- **`AudioPlayerService+Queue.swift`** (738 lines) — queue state,
  shuffle/repeat, seek, auto-advance, scrobble forwarding, library track
  start.
- **`AudioPlayerService+NowPlayingInfo.swift`** (380 lines) —
  `MPNowPlayingInfoCenter` publishing + `MPRemoteCommandCenter` registration.
- **`AudioPlayerService+Reconnect.swift`** (297 lines) — reconnect-in-flight
  guard, network path monitor, deferred reconnect, probe-and-retry.
- **`AudioPlayerService+VLCDelegate.swift`** (177 lines) —
  `VLCMediaPlayerDelegate` / `VLCMediaDelegate` conformances.
- **`AudioPlayerService+TimeShift.swift`** (76 lines) — time-shift buffered
  playback.

No renames, no reordering, no new types — each new file is `extension
AudioPlayerService { ... }` containing code moved verbatim from its MARK
section.

### Correctness proof

Swift's `private` is file-scoped, so splitting a single file into several
required widening some declarations to `internal` purely so the extension
files could see them — no other signature changed. The commit widened:

- **69 of 81 stored properties** from `private` to `internal`.
- **28 methods**, including `advance`, `retirePlayer`, `startStream`,
  `syncState`, `probeAndRetryStream`, `claimReconnectGuard` /
  `releaseReconnectGuard`, `startWedgeWatchdog` / `stopWedgeWatchdog`,
  `configureAudioSession`, `configureNetworkPathMonitor`,
  `configureRemoteCommands`, `updateNowPlayingInfo(For Track)`.
- Setter access on 5 `public private(set)` properties to `public
  internal(set)` (`currentQueueIndex`, `nowPlayingArtworkURL`,
  `nowPlayingSubtitle`, `trackDuration`, `trackElapsed`), plus
  `listeningStartDate` / `accumulatedListeningTime`.

External public API is unchanged in every case — only same-module,
cross-file access was added.

To verify zero behavior change, the commit includes a full grep-based
**declaration inventory diff**: every `func`/`var`/`let` declared across the
root file plus all 6 new extension files was compared, as a multiset,
against the declarations in the original single file. The two sides matched
exactly except for the documented visibility widenings above (560
declarations on both sides). Gates: iOS build, 476/476 unit tests, tvOS
build, simulator install + launch — all green.

## Consequences

**Positive:**
- Navigating to a concern (e.g. "how does reconnect work") now means opening
  one ~300-line file instead of scrolling a 3,600-line one or grep-ing MARK
  comments.
- The file layout now mirrors the test suite's existing per-concern split.
- Zero behavior change — this was a pure reorganization, not a refactor.

**Negative / honestly stated:**
- **This is not encapsulation.** Widening 69 of 81 stored properties and 28
  methods to `internal` means any file in the `AdagioStream` module can now
  reach into state that was previously locked to one file. `AudioPlayerService`
  remains **one integrated state machine** — the split improved navigability,
  it did not introduce ownership boundaries. A caller elsewhere in the module
  could still reach around the class's own methods and mutate state directly;
  nothing in this change prevents that except convention.
- The class is still ~3,700 lines of total logic; splitting files did not
  reduce complexity, only relocate it.

**Superseded-by candidate:** `beads_mobilemusic-aqz` — deeper decomposition
(a `NowPlayingInfoBuilder`, a `RemoteCommandConfigurator`, a `PlaybackQueue`
controller, extracting `NetworkPathMonitor`) was assessed during the review
and explicitly deferred as too risky for an unsupervised pass. That work
would introduce real ownership boundaries — extracted types that own their
own state — rather than file boundaries around shared state. It requires a
careful, supervised, behavior-preserving effort with heavy playback testing
given how much of this class borders the VLC-lifecycle and
`AVAudioSession`-ownership core (ADR 0001). This ADR's split is a
prerequisite waypoint, not a substitute, for that work.

**Do not treat file boundaries introduced here as access-control
boundaries.** The next engineer touching this class should assume any
`internal` property listed above can be read or mutated from any of the 7
files.

**Files:**
- `AdagioStream/Services/AudioPlayerService.swift` — root: class decl, stored
  properties, init, core hub methods.
- `AdagioStream/Services/AudioPlayerService+Interruption.swift`
- `AdagioStream/Services/AudioPlayerService+Queue.swift`
- `AdagioStream/Services/AudioPlayerService+NowPlayingInfo.swift`
- `AdagioStream/Services/AudioPlayerService+Reconnect.swift`
- `AdagioStream/Services/AudioPlayerService+VLCDelegate.swift`
- `AdagioStream/Services/AudioPlayerService+TimeShift.swift`
