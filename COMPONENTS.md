# Components & Deployment Tiers

> Produced by `/onboard` on 2026-06-23. The PO ratified a **governing tier of `startup`**
> for all first-party components. See `~/.claude/skills/_shared/deployment-tier.md` for what
> each tier expects from each persona. Team skills (`/grooming`, `/team-plan`, `/standup`,
> `/spike`, `/team-review`, `/postmortem`) read this file to calibrate rigor. Grooming uses
> **strictest-wins per bead**: a bead is groomed at the highest tier of any component it touches.

## Governing tier: `startup`

Rationale: public App Store distribution **including the China storefront**, real end users,
and stored user credentials (M3U / Xtream / planned Navidrome). 8 of 10 personas proposed
`startup`. The IT Architect dissented toward `small-team` (no PII collected, no backend, no
revenue/churn metrics, solo dev) — recorded here so the trade-off stays visible. The PO chose
`startup`.

At `startup` tier, the baseline expectations that are currently **unmet** (tracked as beads):
- Migration safety for persisted user data.
- Accessibility labels on user-facing interactive controls.
- CHANGELOG + release tagging.

## Component inventory

| Component | Path / Target | Tier | Purpose |
|---|---|---|---|
| AdagioStream (iOS app) | `AdagioStream/` (target `AdagioStream`) | startup | Primary consumer app: IPTV/radio audio streaming, CarPlay/AirPlay/background. |
| AdagioStream-tvOS | `AdagioStream-tvOS/` | startup | Apple TV app sharing the core. Currently blocked on Xcode Cloud device registration (`beads_mobilemusic-7u7`). |
| ShareExtension | `ShareExtension/` | startup | Imports provider URLs from the share sheet; writes to the shared app group. |
| CarPlay scene | `AdagioStream/CarPlay/` | startup | In-car browsing + playback. Safety-adjacent and historically the highest-bug surface. |
| Audio pipeline | `AdagioStream/Services/Audio/`, `AudioPlayerService.swift`, `VLCAudioCallbackBridge.{h,m}` | startup | App-owned AVAudioEngine output via libvlc amem callbacks; reliability heart of the app. |
| Credential storage | `KeychainService.swift` + iOS Keychain | startup | Stores provider credentials (Xtream user/pass, planned Navidrome). Security-critical. |
| Local persistence | `PersistenceService.swift` + App Support JSON | startup | Non-secret app data (settings, favorites, groups, saved songs, custom playlists). |
| Navidrome / Subsonic (planned) | new `NavidromeAPI` + new local music store | startup | On-demand music library + queue + offline downloads. Epics `a6f, 0xy, d6q, 1x1, msl, 65x, l31, 8rg`. |
| CI/CD | `.github/workflows/{tests,lint,codeql}.yml`, `ci_scripts/` | startup | GitHub Actions: XCTest suite + SwiftLint on push/PR to `main`/`dev`; `main` requires both checks to merge (branch protection), CodeQL (SAST); Xcode Cloud TestFlight delivery. |
| xmplaylist.com integration | `SXMMetadataService.swift` | external (best-effort) | Unowned 3rd-party SiriusXM metadata. Degrades gracefully; cannot impose our rigor on it. |
| ESPN scores integration | `ESPNScoreService.swift` | external (best-effort) | Unowned 3rd-party scores. Degrades gracefully. |
