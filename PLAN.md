# Time-Shift Buffer Implementation Plan

## Epic: mobilemusic-b3w — Time-shift buffer: continue downloading during interruptions

### How It Works

1. **Interruption begins** → Stop VLC (releases Xtream Codes connection), immediately start URLSession `dataTask` to the same stream URL. Data chunks are appended to a temp `.ts` file on disk.
2. **During interruption** → URLSession continues downloading. Capped at 120s (configurable) to limit storage (~1-2 MB/min).
3. **Interruption ends** → Stop URLSession (releases connection), close file. Reactivate audio session. Play local `.ts` file with VLC.
4. **Catching up** → VLC plays the buffered file. Status shows "Catching up · ~Xs behind". LIVE button appears.
5. **Buffer ends** → VLC reaches end of file → automatically transitions to live stream. LIVE button disappears.
6. **Skip ahead** → User taps LIVE button → stops file playback, starts live stream immediately.

### Connection Limit Handling

VLC and URLSession never overlap — VLC is fully destroyed before URLSession starts, and URLSession is cancelled before VLC reconnects. ~0.3s gap between each swap (acceptable).

### Edge Cases

- **< 1s interruption**: If captured < 4KB, skip buffer playback, go straight to live
- **URLSession fails**: Fall back to normal live restart (no regression)
- **User stops/pauses/changes channel during catch-up**: Cancel buffer, clean up temp file
- **Max duration reached**: Stop capturing, play whatever was buffered when interruption ends
- **Temp file cleanup**: Files in NSTemporaryDirectory, cleaned on transition/stop/app termination

---

## Child Issues (Implementation Order)

### 1. Add debug logger category and constants
- `DebugLogger.swift`: Add `.timeShift` category
- `Constants.swift`: Add `maxTimeShiftDuration = 120`, `minTimeShiftBytes = 4096`

### 2. Create TimeShiftBufferService
- New file: `Services/TimeShiftBufferService.swift`
- `@MainActor ObservableObject` singleton with state machine
- States: idle → capturing → readyToPlay → playingBuffer → transitioningToLive
- `@Published var isTimeShifted: Bool` for UI binding
- `startCapture(for:)` — creates temp file, starts URLSession dataTask with delegate
- `stopCapture() -> URL?` — cancels task, closes file, returns URL (or nil if < minBytes)
- `cancelAndCleanup()` — abort everything and delete temp file
- URLSessionDataDelegate: append chunks to FileHandle on dedicated serial queue
- Duration timer: estimate captured seconds from bytes + last known bitrate

### 3. Integrate time-shift into AudioPlayerService interruption handlers
- `.began`: After `stop()`, 0.3s delay then `timeShiftBuffer.startCapture(for: channel)`
- `.ended`: `timeShiftBuffer.stopCapture()` → pass file URL to `reactivateAndPlay(channel:bufferFileURL:)`
- Add `bufferFileURL: URL? = nil` parameter to `reactivateAndPlay`
- Same pattern for `handleSilenceSecondaryAudio`

### 4. Add buffer playback and live transition to AudioPlayerService
- New `playBufferedFile(_ fileURL:, for channel:)` — plays local .ts with VLC
- New `isPlayingBufferedFile`, `bufferedChannel` private properties
- `syncState()` `.ended` case: detect buffer end → trigger `play(channel:)` for live
- `updateStreamStats()`: show "Catching up" status when time-shifted
- `updateNowPlayingInfo()`: set `isLiveStream: false` when time-shifted
- New `skipToLive()` public method
- Cleanup in `stop()`, `pause()`, `play(channel:)`

### 5. Add LIVE button to NowPlayingView
- Orange status dot + catch-up text + red LIVE capsule button when time-shifted
- Tapping LIVE calls `audioPlayer.skipToLive()`
- Conditional: hide normal green dot / "Live" status when time-shifted

### 6. Add LIVE button to MiniPlayerView
- Compact orange status + inline red LIVE capsule when time-shifted
- Same `skipToLive()` action

### 7. Build, test, and verify
- Build and install in simulator
- Manual verification: Siri trigger, LIVE button, stop during catch-up, channel change
