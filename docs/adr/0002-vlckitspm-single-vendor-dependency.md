# ADR 0002: VLCKitSPM as a single-vendor media engine dependency

**Status:** Accepted

---

## Context

Adagio Stream must play streams from two fundamentally different source types:

1. **IPTV streams** (M3U / Xtream Codes) — arbitrary codecs, container formats,
   and transports including MPEG-TS, HLS, AAC, MP3, and whatever the IPTV provider
   has deployed.
2. **Navidrome / Subsonic music** — server-transcoded audio in formats the server
   chooses (typically MP3 or AAC), plus whatever the original file format is when
   transcoding is disabled.

AVPlayer (the Apple-native option) handles a well-defined subset of codecs and
containers.  It works well for HLS and AAC but fails silently or errors on many
IPTV streams that use non-standard TS wrapping or older codec variants.  Switching
to AVPlayer as the IPTV engine would require maintaining a compatibility shim,
ongoing stream-level testing against dozens of provider configurations, and still
would not handle all the edge cases that field reports surface.

libvlc (exposed via VLCKit) handles the full codec variety with decades of
battle-testing across IPTV and media playback use cases.

The specific dependency chosen is [VLCKitSPM](https://github.com/tylerjonesio/vlckit-spm)
(`exactVersion: "3.6.0"` in `project.yml`), a Swift Package Manager distribution
of MobileVLCKit maintained by a single external contributor.  This is not the
official VideoLAN VLCKit distribution, which ships only as a CocoaPod or binary
framework download; VLCKitSPM is the only practical path to SPM integration.

## Decision

Accept VLCKitSPM as the sole media engine dependency.  The trade-off — accepting
lock-in to a single-maintainer external package — is accepted with eyes open
because:

- No other practical option covers the full codec range required by the user base.
- The binary is pinned to `exactVersion: "3.6.0"` to prevent surprise breakage
  from upstream updates.
- The amem PCM-callback architecture (ADR 0001) reduces the surface area of the
  VLCKit integration: the app does not rely on VLCKit's AVAudioSession management,
  only on its decoder and network-caching pipeline.  If VLCKit is ever replaced,
  the audio output side (`AudioOutput.swift`, `VLCAudioCallbackBridge`) would stay.

## Consequences

**Positive:**
- Full codec and container coverage for IPTV and Subsonic streams without
  maintaining a per-codec shim layer.
- SPM integration keeps the project buildable without CocoaPods or manual framework
  downloads.
- `exactVersion` pin gives deterministic builds across all developer and CI machines.

**Negative / trade-offs:**
- VLCKitSPM is maintained by a single external contributor, not VideoLAN directly.
  If the maintainer stops publishing updates, the project would need to fork and
  publish its own SPM wrapper or switch distribution mechanisms.
- libvlc adds significant binary size (~50 MB compressed framework).
- The exit path to AVPlayer is non-trivial.  It would require: auditing all active
  provider stream formats for AVPlayer compatibility, rewriting the network-caching
  and retry logic that today relies on VLC's internal buffering, and replacing the
  amem ring-buffer audio pipeline with an AVPlayer-based output.  Estimate: a
  significant multi-epic effort with probable regression risk on IPTV streams.
- VLC 3.x amem quirks (S16N hardcode, documented in ADR 0001) are an ongoing
  maintenance surface if VLCKit is updated to VLC 4.x.

**Exit criteria that would trigger re-evaluation:**
- VLCKitSPM maintainer stops publishing security or compatibility updates for two
  or more consecutive Xcode/iOS major releases.
- A specific codec or transport requirement arises that VLC cannot handle but an
  alternative engine can.
- Binary size constraints require a lighter engine for a new target (e.g., watchOS).

**Files:**
- `project.yml` — `packages.VLCKitSPM` section
