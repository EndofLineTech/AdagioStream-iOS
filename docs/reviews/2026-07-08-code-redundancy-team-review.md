# Team Review: Code Redundancy / Duplication / Inefficiency Audit

- **Date:** 2026-07-08
- **Review target:** Entire AdagioStream-iOS codebase (iOS app, tvOS app, ShareExtension, CarPlay, CI, docs, beads board)
- **Depth:** Quick (top findings per persona)
- **Tier calibration:** `startup` (per `COMPONENTS.md`)
- **Participants:** Security Engineer, IT Architect, Project Manager, Project Engineer, UX Designer, Code Reviewer, Database Engineer, SRE, QA Engineer, Technical Writer
- **Tracking:** beads_mobilemusic-dar

## Summary

The codebase is in better shape than a cold audit usually finds. Credential handling, the provider abstraction, tvOS layering, the VLC audio callback bridge, and the parser layer all came back clean, and several reviewers explicitly credited restraint (e.g., `APISession.swift` correctly *not* DRY'd into a factory). The real findings cluster in four places: duplicated small helpers in the SwiftUI views (some with live user-visible bugs), hand-synced parallel state in `ProviderManager` and settings persistence, uncoordinated retry machinery in `AudioPlayerService`, and stale docs/board entries. Nothing rated Critical.

The strongest signal is independent convergence: four personas separately found the duration-formatter clone family; two independent pairs found the app-group string literals, the dead `PLAN.md`, the README/CLAUDE.md command duplication, and the `ProviderManager` favorite-sync fragility.

## Findings

Severity scale: **High** = correctness or user-visible today · **Medium** = drift risk, cheap consolidation · **Low** = hygiene.

### High value — correctness or user-visible today

| # | Finding | Flagged by | Location | Minimal fix |
|---|---------|-----------|----------|-------------|
| 1 | `formatDuration`/`formatTime` cloned 7× across 6 files, with a live bug: the 4 byte-identical SwiftUI copies have no hour rollover, so a track over an hour renders "125:30" in-app while CarPlay (the only tested copy) correctly shows "2:05:30". Two copies share a name but produce different output in the same file (`PlaylistBrowseView`). Zero of the 4 buggy copies are tested. | UX, Code Reviewer, Engineer, QA | `AlbumDetailView.swift:420`, `GenreBrowseView.swift:334`, `SearchResultsView.swift:321`, `PlaylistBrowseView.swift:666`, `NowPlayingView.swift:445` + `:586`; correct version at `CarPlayTemplateManager.swift:1102` | One shared helper in `Utilities/Extensions.swift`, ported from CarPlay's tested `h:mm:ss` version; delete the copies. Net-negative LOC; closes the coverage gap for free. Keep the two deliberately different formats (`PlaylistBrowseView:577` "N hr M min", CarPlay elapsed-time) distinct. |
| 2 | `settings.json` has two independent writers doing read-modify-write with no coordination — a lost-update race. `SettingsViewModel` and `AudioPlayerService.persistQueuePreferences()` each load, mutate, and rewrite the whole file from separate in-memory copies; a shuffle toggle racing a Settings-screen toggle silently drops one change. The `PersistenceService` actor makes each write atomic but not the load-then-save pair. | Database Engineer | `SettingsViewModel.swift:122`, `AudioPlayerService.swift:1645-1654` | Route repeat/shuffle writes through the single `SettingsViewModel` owner; eliminate the second load-modify-save site. No new abstraction. |
| 3 | Four independent reconnect/retry mechanisms in `AudioPlayerService` with no shared in-flight guard: probe-retry (exponential backoff), deferred reconnect (1s poll ×90), watchdog restart (no backoff), and path-monitor force-play (flat 5s cooldown). On a flaky connection two or more can independently tear down and rebuild the VLC player around the same moment — a restart-storm / watchdog-kill risk. | SRE | `AudioPlayerService.swift:2364-2442`, `:2195-2216`, `:3101-3137`, `:868-913` | One "reconnect in flight" guard (a `Date?`/bool) checked by all four entry points; generalize the existing `pathReconnectCooldown` pattern. |
| 4 | Xtream and Navidrome each hand-roll the same retry-on-5xx fetch helper; the copies have already drifted (Xtream also retries decode errors, Navidrome doesn't, undocumented) and only Navidrome's copy is tested. Xtream's network layer — the app's original load-bearing path — has zero tests despite the reusable `MockURLProtocolHandler` harness already existing. | Code Reviewer, QA | `XtreamCodesAPI.swift:185-213` vs `NavidromeAPI.swift:1190-1221`; harness at `NavidromeAPITests.swift:9` | Extract the identical retry loop into a small shared function (or at minimum document the intentional drift); add a `session:` injection point to `XtreamCodesAPI` and port the two existing 500-retry tests plus one auth-failure test. Do **not** build a shared `APIClient` base class. |
| 5 | `URL.redactedForLog` only knows Xtream credential shapes — Subsonic's `u`/`p`/`t`/`s` query params aren't covered, so any future log of a Navidrome request URL would leak credentials. No current violation found; latent trap with two credential schemes and one one-scheme redactor. | Security | `Extensions.swift:43-68`; second ad-hoc redaction at `NavidromeAPI.swift:1282-1285` | Add the 4 Subsonic param names to `redactedForLog`'s redaction set (~4 lines) so one helper is safe for both provider types. |
| 6 | CarPlay error states are inconsistent by nesting depth: root-level music lists swallow network errors and show "No artists" (reads as an empty library); nested lists correctly show "Failed to load". Six copies of the same load→populate→catch skeleton. | UX | `CarPlayTemplateManager.swift:790-833` (root, silent) vs `:940-1062` (nested, correct) | Route the root-level catch blocks through the same "Failed to load" fallback the nested pushers already use. |

### Medium — drift risk, cheap consolidation

| # | Finding | Flagged by | Location | Minimal fix |
|---|---------|-----------|----------|-------------|
| 7 | App-group ID `"group.com.adagiostream.app"` + `"pendingSharedURLs"` as raw string literals in 3 files — the cross-target ShareExtension handoff boundary, silently breakable by one typo. `Constants.swift` already exists for exactly this category. | Security, Architect | `ShareViewController.swift:6-9`, `ContentView.swift:129-143`, `DataDeletionService.swift:38-39` | Two `static let`s in `Constants.swift`; add that file to ShareExtension's `sources:` in `project.yml`, re-run `xcodegen generate`. |
| 8 | `addProvider`/`updateProvider` share a 46-line validation block, identical except the log-prefix string — a historical hotspot (post-incident "REJECTED" logging) that must now be patched twice. | Engineer | `ProviderManager.swift:122-168` vs `:235-280` | Extract `private func validateProvider(_:context:)` — two real call sites, earns the extraction. |
| 9 | `isFavorite` hand-synced across three parallel arrays (`channels`/`rawChannels`/`providerRawChannels`) in 3 write sites — 9 hand-rolled index-and-mutate scans for one logical operation. Fragile, not yet a bug. | DBA, Engineer | `ProviderManager.swift:574-596`, `:617-630`, `:637-660` | One private `setFavorite(_:forChannelID:)` helper called from all 3 sites. Both personas explicitly warn **against** restructuring the three-array design itself in this pass. |
| 10 | The loading/empty/error `switch` for async list state is copy-pasted 7× across the music browse screens — a code comment in `PlaylistBrowseView` admits the copy. No drift yet; 7 places to update on the next loading/retry UX tweak. | UX | `AlbumDetailView.swift:55-99`, `ArtistDetailView.swift`, `BrowseAlbumsView.swift:60-108`, `GenreBrowseView.swift:36-97` (×2), `SearchResultsView.swift:45-94`, `PlaylistBrowseView.swift:110-154` + `:340-388` | One shared loadable-content helper/view keeping today's exact visuals; all 7 call sites route through it. |
| 11 | Three near-identical track-row views with drifted interaction: album rows are tap-only, playlist/genre rows have inline play (and star/download) buttons — the same action gets different controls depending on the screen. | UX | `AlbumDetailView.swift:362-425`, `PlaylistBrowseView.swift:595-664`, `GenreBrowseView.swift:267-332` | One `TrackRowView` with optional slots (the pattern `PlaylistTrackRowView` already uses); delete the other two. |
| 12 | Dead code in `NavidromeAPI`: `getSongsByGenre` and `search3` (plain variants) have zero production callers — superseded by the `WithStarState` variants — and are kept alive only by ~15 of their own test cases (false confidence). | Engineer | `NavidromeAPI.swift:586-599`, `:653-684`; tests at `NavidromeAPITests.swift:546-868` | Delete both functions and their dedicated tests (~46 app lines + test maintenance). |
| 13 | `AudioPlayerService.swift` is 3,603 lines / 24 MARK sections / one class, zero file splits — the test suite is already split by concern (Scrobble, NowPlaying, Shuffle, Interruption…) but the source never got the equivalent split. | Architect | `AudioPlayerService.swift` (whole file); contrast `Services/Audio/AudioOutput.swift` (265 lines, correctly extracted) | Mechanical split into `extension AudioPlayerService` files along existing MARK boundaries. Zero behavior change, no new types. Timing dispute — see Conflicts. |
| 14 | `DebugLogger` opens/seeks/closes the file handle (plus a stat call) on every single log call — hottest exactly during wedge/reconnect storms when log volume peaks. | SRE | `DebugLogger.swift:161-182` | Keep one `FileHandle` open for process lifetime; reopen only after rotation (~10 lines). |
| 15 | Two permanent, never-torn-down resources armed in `init()`: `wedgeWatchdogTimer` (5s, app lifetime) and `NWPathMonitor` (never `cancel()`ed) — the same pattern class as the idle-timer leak fixed in `ad15f49`. | SRE | `AudioPlayerService.swift:55/383` (timer), `:269/865` (monitor) | Gate the watchdog to active playback (start in `play()`, stop in `stop()`); cancel or explicitly document the monitor as intentionally permanent. |
| 16 | `stateTimer` construction closure duplicated verbatim 4× (each site correctly invalidates first — pure duplication, not a leak). | SRE | `AudioPlayerService.swift:2017-2021`, `:2353-2357`, `:2561-2565`, `:2618-2622` | Extract `startStateTimer(interval:)` doing invalidate+reassign; 24 lines → ~8. |
| 17 | ATS `NSAppTransportSecurity` block duplicated byte-for-byte between iOS and tvOS Info.plists — and it's decorative: `NSAllowsArbitraryLoads=true` makes the three exception domains inert. The comment "mirrors iOS target" admits the hand-sync. | Security, Architect | `AdagioStream/Info.plist:29-57`, `AdagioStream-tvOS/Info.plist:25-53`, mirrored in `project.yml` | Disputed — see Conflicts and Decision 1. |

### Low — hygiene: docs, board, small deletions

| # | Finding | Flagged by | Location | Minimal fix |
|---|---------|-----------|----------|-------------|
| 18 | `PLAN.md` at repo root is a dead plan for the Time-Shift Buffer feature that shipped in v1.0.0; it references bead `mobilemusic-b3w`, which no longer exists. Nothing links to it. | PM, Tech Writer | `PLAN.md` | Delete. Git history preserves it. |
| 19 | README structure tree lists deleted `Favorites/` and `Library/` view folders; the "Favorites" feature bullet describes a screen that no longer exists; CHANGELOG `[Unreleased]` names the superseded five-tab layout. All predate commit `a62ea43` (tab-bar rename). | Tech Writer | `README.md:35`, `:105-110`; `CHANGELOG.md:29` | Update the tree, reword the Favorites bullet ("pinned at the top of the Live tab"), fix the Unreleased bullet — free while untagged. |
| 20 | Build/test/versioning commands duplicated verbatim between README.md and CLAUDE.md, already textually diverged (separate lines vs `;`/`&&` chaining). | PM, Tech Writer | `README.md:64-88` vs `CLAUDE.md` Building/Testing/Versioning | Keep CLAUDE.md as the survivor; README links to it instead of restating commands. |
| 21 | COMPONENTS.md's unmet-baseline list claims "today CI only builds via CodeQL," but `tests.yml` and `lint.yml` exist alongside `codeql.yml` (PM confirmed the three workflows are distinct and non-overlapping). | Tech Writer, PM | `COMPONENTS.md:18`, `.github/workflows/` | Verify `tests.yml` actually gates, then update or remove the stale line. |
| 22 | Board hygiene: spike `beads_mobilemusic-r0p` is done-but-open (its GO recommendation is already implemented in the codebase); P1 bugs `46u`/`lfn`/`of1` are three parallel issues all awaiting the same CarPlay field-validation drive; `4yg.9` is an orphaned P2 hanging off a closed epic, stale 42 days. Prefix split (`beads_mobilemusic-`/`mobilemusic-`) confirmed archival-only — no live duplicates, no action. | PM | beads board | Close `r0p` with commit reference; check the debug log and close confirmed CarPlay bugs / merge remaining verification into one checklist; decide or defer `4yg.9`. ~6-8 steps total including #18/#20. |
| 23 | Small deletions/extractions: dead `InteractiveGlassButtonStyle` (zero call sites); stale 65-line `advance()` doc block whose live implementation sits 80 lines below (and holds the only copy of a gapless TODO); two tests burning real 2s sleeps via the retry path (no injectable delay); `Track` test fixture duplicated 5× + `NavidromeStore(writer:)` setup 3× with no TestSupport convention; CarPlay `trackDetailText(for:)` duplicating `trackDetailTextByID(_:)`; Now Playing publish/log tail duplicated between the radio and music update paths. | Code Reviewer, SRE, QA, Engineer | `GlassEffect+Helpers.swift:19-29`; `AudioPlayerService.swift:1336` + `:1418`, `:2053-2136` + `:3356-3447`; `NavidromeAPITests.swift:201/:221`; `PlaybackQueueTests.swift` et al.; `CarPlayTemplateManager.swift:591-603` vs `:659-671` | Each is a few lines: delete the dead style and stale doc block; add a `Duration` parameter for retry delay (default 2s, zero in tests — no `Clock` protocol); one `TestSupport/TrackFixtures.swift`; have `trackDetailText(for:)` call `trackDetailTextByID(_:)`; extract a small `publishNowPlayingInfo` tail helper (keep the differing source-selection logic separate). |

## Conflicts

### ATS block (finding 17)

- **Security says:** the exception-domains dict is dead config under `NSAllowsArbitraryLoads=true` — delete it from both plists rather than build sync tooling. Deletion is honest about the actual posture ("we don't rely on ATS," defensible since libvlc doesn't route through ATS anyway).
- **Architect says:** keep it synced via a YAML anchor in `project.yml` (native feature, single source of truth), or accept the duplication — while noting the anchor carries a discoverability tax.
- **Both agree** the deeper question is whether ATS should actually be *enforced* (arbitrary-loads off, keep the exceptions) — a security-posture change requiring PO decision and testing against user-supplied IPTV/Navidrome hosts, not a redundancy cleanup.

### `AudioPlayerService` split timing (finding 13)

- **Architect says:** do the mechanical extension-file split now; every playback feature pays a re-orientation tax in this file.
- **Engineer position (pre-acknowledged by the architect):** it's a large no-behavior-change diff that will conflict with the in-flight interruption/CarPlay hotfix stream — 5 of the last 5 commits touch this file and three P1s are still awaiting field validation against it. If done, it must be a standalone commit between landings.

### Consolidation appetite (cross-cutting)

Engineer and DBA both explicitly fenced off bigger rewrites: no reactive channel-store rework for the three-array design (#9), no shared `APIClient` base class (#4), no `NowPlayingInfoBuilder` abstraction (#23). Every recommended fix in this report is a deletion, a helper extraction with 2+ existing call sites, or a doc edit.

## Positive observations

- **Credential handling** (`KeychainService` + `KeychainSyncMigrator`): single service identifier, shared query helpers, no drift. Xtream URL construction and `SubsonicAuth` each single-sourced.
- **Provider abstraction**: a plain three-case enum with one `switch` — the right amount of structure for three fixed provider kinds; a `StreamProvider` protocol would be the over-engineered version.
- **tvOS target**: thin platform shims (48-100 lines each) over shared services, not copy-pasted iOS views.
- **Audio hot path**: `VLCAudioCallbackBridge.m` is allocation-free, lock-free, log-free — correctly designed for a real-time thread. Interruption/route-change handling is fully centralized; the `AudioOutput` interruption gate has dedicated pure-function tests.
- **`APISession.swift`** and the ADR-0004 / gapless design-doc pairing are both examples of deliberately *not* deduplicating where duplication is cheaper than the abstraction.
- **Test suite**: 27 files / ~7,500 lines / ~190 cases, no skipped tests, no real-network calls.

## Open decision points (for the PO)

1. **ATS posture (finding 17):** (a) delete the inert exception-domains block from both plists — security's recommendation; (b) enforce ATS for real (arbitrary-loads off) — a behavior change needing testing against user-supplied hosts; or (c) keep as-is with a YAML anchor in `project.yml`.
2. **`AudioPlayerService` split (finding 13):** split now as a standalone commit, or defer until the three in-flight P1 interruption bugs (`46u`/`lfn`/`of1`) are field-confirmed and closed. Team lean: defer until those close, then split before the next feature lands in that file.
3. **Bead filing:** which findings get filed as backlog items. Suggested cut: #1–#6 as P1/P2, #7–#17 as P2/P3, #18–#23 as a single hygiene task plus the three board actions in #22.

---

*Produced by a 10-persona parallel team review (quick depth). Reviewers were read-only; no fixes were applied. Findings calibrated to `startup` tier — items that would only be findings at enterprise tier (cert pinning, formal stale-issue SLAs, snapshot-test catalogs, VACUUM scheduling) were noted by reviewers but excluded here.*
