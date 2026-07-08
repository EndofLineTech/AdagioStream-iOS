# Adagio Stream

A feature-rich audio streaming app for iOS. Connect IPTV providers and Navidrome music
libraries, browse and search your content, and listen with CarPlay, AirPlay, and
background playback support.

## Features

### IPTV streaming (M3U / Xtream Codes)

- **Multi-Provider Support** — Connect M3U playlists and Xtream Codes providers simultaneously
- **Channel Groups** — Organize, enable/disable, and favorite groups with custom sort order
- **EPG** — Electronic program guide integration for both M3U and Xtream Codes
- **SiriusXM Metadata** — Automatic track detection with song title, artist, and artwork via xmplaylist.com
- **Live Sports Scores** — Real-time NFL, MLB, NBA, and NHL scores from ESPN on matched channels
- **Saved Songs** — Save tracks you hear on SiriusXM channels to your library
- **Custom Playlists** — Create and share custom channel playlists

### Navidrome music library (Subsonic API)

- **Music Library** — Browse artists, albums, and genres with cover art from a Navidrome server
- **Search** — Full-text search across artists, albums, and songs
- **Queue Playback** — Next/previous, auto-advance, shuffle, and repeat; lock-screen scrubber
- **Playlists** — Browse, play, create, rename, delete, and edit track lists
- **Scrobble** — Automatically report plays to the Navidrome server
- **Stars and Ratings** — Star/unstar tracks and set ratings; starred indicator in browse rows
- **Offline Downloads** — Background downloads with byte-range resume; local-first playback
- **Offline Mode** — Falls back to downloaded library when the server is unreachable

### Platform

- **CarPlay** — Full channel and music library browsing, now-playing controls, Up Next queue
- **AirPlay** — Stream to any AirPlay-compatible device
- **Time-Shift Buffer** — Seamless audio continuity during phone calls and interruptions with skip-to-live
- **Favorites** — Favorited channels pin to the top of the Live tab for quick access
- **Share Extension** — Import provider URLs directly from the share sheet
- **Privacy First** — Zero analytics, zero tracking, all data stored locally on device
- **GDPR Compliant** — Export your data, delete all data, in-app privacy policy

## Requirements

- iOS 17.0+
- Xcode 26.0+ (required — project uses iOS 26 Liquid Glass APIs gated by `#available`)
- Swift 5.9

## Setup

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project configuration and [beads](https://github.com/MotWakorb/beads) for issue tracking.

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate Xcode project
xcodegen generate

# Set up beads issue tracking
chmod 700 .beads
bd bootstrap
bd import
bd hooks install
```

## Building

```bash
# Build for simulator
xcodebuild -scheme AdagioStream -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Install and launch in simulator
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null
xcrun simctl install "iPhone 17 Pro" ~/Library/Developer/Xcode/DerivedData/AdagioStream-*/Build/Products/Debug-iphonesimulator/AdagioStream.app
xcrun simctl launch "iPhone 17 Pro" com.adagiostream.app
```

## Testing

```bash
xcodebuild test -scheme AdagioStream -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AdagioStreamTests
```

## Versioning

Bump `CURRENT_PROJECT_VERSION` in `project.yml`, then regenerate:

```bash
xcodegen generate
```

## Project Structure

```
AdagioStream/
├── Models/           Data structures (Provider, Channel, NavidromeModels, etc.)
├── Services/         Business logic
│   ├── Audio/        AVAudioEngine + VLCAudioCallbackBridge (amem PCM pipeline)
│   ├── AudioPlayerService.swift
│   ├── NavidromeAPI.swift      Subsonic REST client
│   ├── NavidromeStore.swift    GRDB SQLite library + download index
│   ├── SubsonicAuth.swift      Token + salt MD5 authentication
│   ├── DownloadManager.swift   Background URLSession downloads + byte-range resume
│   └── ...                     ProviderManager, ESPN, SXM, EPG, etc.
├── ViewModels/       MVVM view state management
├── Views/            SwiftUI interface (Channels, Music, Player, SavedSongs,
│                     CustomPlaylists, EPG, Provider, Settings, Setup, Components)
├── CarPlay/          CarPlay scene and template manager
├── Utilities/        Constants, extensions, helpers
└── Resources/        Licenses, assets
docs/adr/             Architecture Decision Records
AdagioStreamWidget/   Lock screen and Live Activity widget
ShareExtension/       URL share sheet handler
```

## Dependencies

- **[VLCKitSPM](https://github.com/tylerjonesio/vlckit-spm)** v3.6.0 — LibVLC-based audio playback (see [ADR 0002](docs/adr/0002-vlckitspm-single-vendor-dependency.md))
- **[GRDB.swift](https://github.com/groue/GRDB.swift)** v6.29.3 — SQLite persistence for the Navidrome library and download index

No third-party analytics, crash reporting, or advertising SDKs.

## Privacy

Adagio Stream does not collect, store, or transmit any personal data. See [PRIVACY_POLICY.md](PRIVACY_POLICY.md) for full details.

- No analytics or telemetry
- No advertising
- No device identifiers or tracking
- All data stored locally on device in the iOS Keychain and app sandbox
- Debug logs automatically redact credentials
- GDPR compliant with data export and deletion controls

## License

Adagio Stream is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0), with an additional permission under section 7 allowing distribution through Apple's App Store. See [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 End of Line Technologies
