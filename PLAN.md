# Adagio Stream — iOS Audio IPTV Player

## Context
Build a greenfield iOS app that connects to IPTV providers (via M3U/EPG or Xtream Codes API) and plays channels as **audio only**. The app targets iOS 16+, uses SwiftUI, and supports CarPlay, background audio, configurable buffering, channel search, and favorites.

---

## Project Structure

```
AdagioStream/
├── AdagioStreamApp.swift                 # App entry point, scene configuration
├── Info.plist                            # Background modes, CarPlay entitlement
├── AdagioStream.entitlements
│
├── Models/
│   ├── Channel.swift                     # Channel data model (Codable, Identifiable)
│   ├── EPGEntry.swift                    # EPG program entry model
│   ├── Provider.swift                    # IPTV provider connection (M3U or XC)
│   ├── ChannelGroup.swift                # Category/group model
│   └── AppSettings.swift                 # User settings (buffer duration, etc.)
│
├── Services/
│   ├── M3UParser.swift                   # Parse M3U/M3U8 playlists
│   ├── EPGParser.swift                   # Parse XMLTV EPG data (XMLParser-based)
│   ├── XtreamCodesAPI.swift              # XC REST API client (async/await)
│   ├── AudioPlayerService.swift          # AVPlayer wrapper, background audio, Now Playing
│   ├── PersistenceService.swift          # JSON file storage for favorites/settings/providers
│   └── ProviderManager.swift             # Orchestrates loading channels from any provider type
│
├── ViewModels/
│   ├── ProviderListViewModel.swift       # Manage provider CRUD
│   ├── ChannelListViewModel.swift        # Channel list, search, filtering, grouping
│   ├── PlayerViewModel.swift             # Playback state, now playing info
│   ├── FavoritesViewModel.swift          # Favorites management
│   └── SettingsViewModel.swift           # Settings management
│
├── Views/
│   ├── ContentView.swift                 # Root TabView
│   ├── Provider/
│   │   ├── ProviderListView.swift        # List of configured providers
│   │   └── AddProviderView.swift         # Add/edit M3U URL or XC credentials
│   ├── Channels/
│   │   ├── ChannelListView.swift         # Grouped channel list with search bar
│   │   └── ChannelRowView.swift          # Single channel row (name, logo, favorite toggle)
│   ├── Player/
│   │   ├── NowPlayingView.swift          # Now playing screen (channel, EPG, controls)
│   │   └── MiniPlayerView.swift          # Persistent mini player bar
│   ├── Favorites/
│   │   └── FavoritesView.swift           # Favorited channels list
│   ├── EPG/
│   │   └── EPGView.swift                 # EPG schedule for current channel
│   └── Settings/
│       └── SettingsView.swift            # Buffer config, about, provider management
│
├── CarPlay/
│   ├── CarPlaySceneDelegate.swift        # CPTemplateApplicationSceneDelegate
│   └── CarPlayTemplateManager.swift      # Build CPTabBar, lists, now playing templates
│
└── Utilities/
    ├── Constants.swift                   # App-wide constants
    └── Extensions.swift                  # Date, String, URL helpers
```

---

## Key Data Models

### Channel
```swift
struct Channel: Codable, Identifiable, Hashable {
    let id: String            // unique identifier (stream_id or generated)
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let group: String         // category name
    let epgChannelID: String? // tvg-id for EPG matching
    var isFavorite: Bool
}
```

### Provider
```swift
struct Provider: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: ProviderType

    enum ProviderType: Codable {
        case m3u(url: URL, epgURL: URL?)
        case xtreamCodes(host: URL, username: String, password: String)
    }
}
```

### AppSettings
```swift
struct AppSettings: Codable {
    var bufferDuration: TimeInterval  // seconds, default 10
    // extensible for future settings
}
```

---

## Core Services

### M3U Parser
- Line-by-line parser handling `#EXTM3U`, `#EXTINF` directives
- Extracts: `tvg-id`, `tvg-name`, `tvg-logo`, `group-title` from attributes
- Stream URL from the line following `#EXTINF`
- Handles both local file and remote URL loading (async)

### EPG Parser (XMLTV)
- Uses Foundation `XMLParser` (delegate-based)
- Parses `<channel>` and `<programme>` elements
- Maps programmes to channels via `tvg-id` / channel ID
- Returns `[String: [EPGEntry]]` keyed by channel ID

### Xtream Codes API Client
- Base URL: `{host}/player_api.php?username={user}&password={pass}`
- Endpoints:
  - Auth: `&action=` (empty — returns server info + auth status)
  - Categories: `&action=get_live_categories`
  - Live streams: `&action=get_live_streams` (optional `&category_id=`)
  - EPG: `&action=get_short_epg&stream_id={id}` and `&action=get_simple_data_table&stream_id={id}`
- Stream URL format: `{host}/live/{user}/{pass}/{stream_id}.ts` (or `.m3u8`)
- Uses `URLSession` with async/await, `JSONDecoder`

### Audio Player Service
- Wraps `AVPlayer` for audio-only streaming
- `AVAudioSession` configured for `.playback` category (background audio)
- `AVPlayerItem.preferredForwardBufferDuration` set from user settings
- Integrates `MPNowPlayingInfoCenter` (title, artist/channel, artwork)
- Integrates `MPRemoteCommandCenter` (play, pause, stop, next/previous channel)
- Publishes playback state via `@Published` properties or Combine
- KVO on `AVPlayerItem.status` and `AVPlayer.timeControlStatus` for state tracking

### Persistence Service
- Stores JSON files in `Application Support/Adagio Stream/`
- Files: `providers.json`, `favorites.json`, `settings.json`
- Generic `save<T: Codable>(_ value: T, to filename: String)` / `load<T>(from:) -> T`
- Thread-safe with actor isolation

---

## CarPlay Integration

### Setup
- `Info.plist`: Add `UIApplicationSceneManifest` with CarPlay scene config
- Entitlement: `com.apple.developer.carplay-audio` (requires Apple approval for App Store)
- `CarPlaySceneDelegate` implements `CPTemplateApplicationSceneDelegate`

### Template Structure
- `CPTabBarTemplate` with 3 tabs:
  1. **Favorites** — `CPListTemplate` of favorited channels
  2. **Categories** — `CPListTemplate` → drill into channels per category
  3. **Now Playing** — `CPNowPlayingTemplate` (system-provided)
- Channel selection triggers `AudioPlayerService.play(channel:)`
- Templates update reactively when favorites/channels change

---

## Info.plist & Entitlements

- `UIBackgroundModes`: `audio`
- `com.apple.developer.carplay-audio`: `true`
- Scene manifest with both UIKit window scene (for SwiftUI) and CarPlay scene

---

## Build Phases (Implementation Order)

### Phase 1: Foundation
1. Initialize Xcode project (SwiftUI App lifecycle, iOS 16+)
2. Create all data models (`Channel`, `Provider`, `EPGEntry`, `ChannelGroup`, `AppSettings`)
3. Implement `PersistenceService` (JSON file storage)
4. Implement `AppSettings` defaults and settings view

### Phase 2: Provider & Parsing
5. Implement `M3UParser`
6. Implement `EPGParser` (XMLTV)
7. Implement `XtreamCodesAPI` client
8. Implement `ProviderManager` (orchestrates loading from any provider type)
9. Build provider management views (add/edit/delete providers)

### Phase 3: Channel Browsing
10. Build `ChannelListViewModel` with search, grouping, filtering
11. Build channel list views (grouped by category, search bar)
12. Implement favorites toggle and `FavoritesView`

### Phase 4: Audio Playback
13. Implement `AudioPlayerService` (AVPlayer, AVAudioSession, buffering)
14. Configure background audio entitlement and audio session
15. Implement `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`
16. Build `NowPlayingView` and `MiniPlayerView`
17. Wire up channel selection → playback

### Phase 5: EPG
18. Wire EPG data to channel views (current/next program)
19. Build `EPGView` for full schedule

### Phase 6: CarPlay
20. Configure scene manifest and entitlements
21. Implement `CarPlaySceneDelegate`
22. Implement `CarPlayTemplateManager` (tab bar, lists, now playing)

### Phase 7: Polish
23. Error handling and loading states throughout
24. Settings view (buffer duration picker, provider management)
25. App icon, launch screen

---

## Verification / Testing
- **M3U parsing**: Test with sample M3U files (standard and extended format)
- **XC API**: Test with real XC credentials (auth, category listing, stream loading)
- **Audio playback**: Verify stream plays, background audio continues, lock screen controls work
- **Buffering**: Change buffer setting, verify `preferredForwardBufferDuration` updates
- **Search**: Type in search bar, verify channel list filters correctly
- **Favorites**: Toggle favorites, verify persistence across app restarts
- **CarPlay**: Test in Xcode CarPlay simulator (Window → Devices → Simulators → CarPlay)
