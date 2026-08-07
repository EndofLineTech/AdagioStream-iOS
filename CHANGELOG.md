# Changelog

All notable changes to Adagio Stream are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Releases

App Store builds are tagged `v<MARKETING_VERSION>-b<CURRENT_PROJECT_VERSION>` on the
commit that bumps `CURRENT_PROJECT_VERSION` in `project.yml`.
Example: the v1.2 series that ships the Navidrome feature set would be
tagged `v1.2-b168` on the build-168 bump commit.  Do not create tags
for internal or TestFlight-only builds; tag only the commit that
corresponds to an actual App Store submission (or a TestFlight build
submitted to external testers).  Xcode Cloud auto-increments the real
TestFlight build number — `CURRENT_PROJECT_VERSION` in `project.yml`
is the baseline; keep it in step (+1 per significant change) to avoid
large jumps that delay ASC processing.

---

## [Unreleased] — v1.2 series

### Added

- **Navidrome music library** — Connect a Navidrome (or any Subsonic-compatible)
  server as a music provider alongside existing M3U and Xtream Codes providers.
  - Browse artists, albums, and genres with cover art.
  - Library tab added to the main interface (Live / Library / Loved / Custom M3Us / Settings).
  - Full-text search across artists, albums, and songs.
  - Playlist browsing, playback as a queue, and full playlist editing
    (create, rename, delete, add/remove tracks).
  - Queue playback with next/previous navigation, auto-advance, shuffle, and
    repeat; lock-screen scrubber and progress display.
  - Scrobble track plays to the Navidrome server (now-playing notification +
    submission after the play threshold).
  - Star/unstar tracks and set ratings (server-side favorites and ratings,
    kept separate from the IPTV channel-favorites list).
  - Starred indicator and play counts surfaced in browse rows.
  - Offline downloads with background URLSession, byte-range resume, and a
    per-track / bulk download UI with storage management.
  - Local-first playback — downloaded tracks play from disk; offline mode
    falls back to local library when the server is unreachable.
  - CarPlay music library browse (artists / albums / playlists → play) and
    now-playing shuffle/repeat controls; Up Next queue list for jumping
    within a music queue.
  - Token + salt MD5 authentication (Subsonic API standard).

### Changed

- CarPlay now-playing controls extended with shuffle/repeat buttons for
  music playback (IPTV radio controls unchanged).
- `PinnedURLSession` renamed to `APISession` — the class does not pin
  certificates; the old name was misleading (ATS hygiene).
- Internal redundancy cleanup across views and services (no user-visible
  change).

### Fixed

- Removed redundant `NSAllowsArbitraryLoadsForMedia` from Info.plist;
  the key is not needed alongside the per-domain ATS exceptions already
  in place (ATS hygiene).
- CI test destination updated from iPhone 16 Pro to iPhone 17 Pro —
  the 16 Pro image is absent from the `macos-26` GitHub Actions runner,
  which caused all unit-test runs to fail.
- Track durations over an hour now display as `h:mm:ss` in album, genre,
  search, and playlist lists (previously overflowed as `m:ss`, e.g. `125:30`).
- CarPlay music lists now show "Failed to load" on network errors instead
  of silently appearing empty.

---

## [1.0.0] — initial release

Initial App Store release. M3U playlist and Xtream Codes IPTV providers,
CarPlay and AirPlay, time-shift buffer, EPG, SiriusXM metadata, ESPN
live scores, favorites, custom playlists, share extension.
