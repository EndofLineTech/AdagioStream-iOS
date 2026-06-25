# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for Adagio Stream.
Each ADR documents a significant technical or product decision: the context that
prompted it, the choice that was made, and the consequences.

ADRs are immutable once accepted.  If a decision is reversed, a new ADR is written
that supersedes the old one; the old ADR's status is updated to "Superseded by
ADR-NNNN".

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-app-owned-avaudioengine-vlc-amem-pipeline.md) | App-owned AVAudioEngine with libvlc amem PCM callbacks | Accepted |
| [0002](0002-vlckitspm-single-vendor-dependency.md) | VLCKitSPM as a single-vendor media engine dependency | Accepted |
| [0003](0003-carplay-no-auto-resume-on-reconnect.md) | CarPlay disconnect/reconnect does not auto-resume playback | Accepted |

## Template

New ADRs follow the structure in each existing file:

```
# ADR NNNN: Title

**Status:** Proposed | Accepted | Superseded by ADR-MMMM

## Context
## Decision
## Consequences
```
