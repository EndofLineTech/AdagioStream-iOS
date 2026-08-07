# ADR 0003: CarPlay disconnect/reconnect does not auto-resume playback

**Status:** Accepted

---

## Context

When a CarPlay session disconnects (user unplugs the cable or loses Bluetooth),
iOS delivers a `templateApplicationScene(_:didDisconnectInterfaceController:)` call
to `CarPlaySceneDelegate`.  An alternative design would be to save the currently
playing channel at disconnect time and auto-resume it on the next
`templateApplicationScene(_:didConnect:)` call.

There are also route-change notifications (`AVAudioSession.routeChangeNotification`)
that fire when the audio route changes — including when CarPlay connects or
disconnects.  Those notifications could also be used to trigger an auto-resume.

## Decision

Do not auto-resume playback on CarPlay reconnect.  Specifically:

1. On disconnect, `CarPlaySceneDelegate.templateApplicationScene(_:didDisconnectInterfaceController:)`
   calls `AudioPlayerService.shared.stopAndClearInterruption()`, which stops the
   stream and clears the `interruptedChannel` state so that no resume is attempted.
2. Route-change handlers (`handleRouteChange`) in `AudioPlayerService` call
   `syncState()` to detect buffering timeouts that expired during suspension, but
   do not initiate a new stream on route changes.
3. On reconnect, `CarPlaySceneDelegate` calls `recoverStaleInterruption()`, which
   recovers only from an *interruption* (phone call, Siri) that started before
   the disconnect — not from a deliberate stop.

## Consequences

**Rationale for this decision:**

- **Driver safety:** Auto-resuming a potentially loud stream immediately on cable
  plug-in, or when the car's audio system hands control back to CarPlay, is
  startling.  The user should choose when audio starts.
- **Predictable state:** A disconnect may mean the user is done listening, parked,
  or handing the phone to a passenger.  Resuming unconditionally violates the
  principle of least surprise.
- **Interruption vs. disconnect:** The existing short-interruption path (ADR 0001)
  already handles brief system interruptions (Siri, calls) seamlessly while the
  CarPlay session remains active.  Disconnect is a different signal — it is not an
  interruption with an implied `.ended` event; it is a user-visible session
  boundary.

**Positive:**
- No unexpected audio starts when the user plugs in or reconnects.
- Clear mental model: audio only plays when the user explicitly selects a channel
  or taps play in the CarPlay interface.

**Negative / trade-offs:**
- Users who disconnect and immediately reconnect (cable wobble, brief Bluetooth
  drop) must re-select a channel.  This is a deliberate UX choice, not an
  oversight.

**Do not change this decision without explicit product owner approval.**  Previous
sessions have flagged the absent auto-resume as a bug; it is not — it is a
documented product decision.

**Files:**
- `AdagioStream/CarPlay/CarPlaySceneDelegate.swift` — `didDisconnectInterfaceController` calls `stopAndClearInterruption()`
- `AdagioStream/Services/AudioPlayerService.swift` — `stopAndClearInterruption()`, `handleRouteChange()`, `recoverStaleInterruption()`
