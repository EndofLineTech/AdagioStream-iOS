// AudioOutputRestartPredicateTests.swift
//
// Unit tests for the 46u fix: AudioOutput.shouldRestartEngineOnConfigChange
// is a static pure function that determines whether the AVAudioEngine should
// be restarted when AVAudioEngineConfigurationChange fires.
//
// These tests exercise every combination of (intendedToRun, isInterrupted)
// to guarantee the gate logic is correct without instantiating AudioOutput or
// touching the live AVAudioEngine / AVAudioSession.
//
// Combinations:
//   intendedToRun=false, isInterrupted=false → no restart (idle)
//   intendedToRun=false, isInterrupted=true  → no restart (idle + interrupted)
//   intendedToRun=true,  isInterrupted=true  → no restart (the 46u case: ride-out)
//   intendedToRun=true,  isInterrupted=false → restart (normal post-interruption resume)

import XCTest
@testable import AdagioStream

final class AudioOutputRestartPredicateTests: XCTestCase {

    // MARK: - shouldRestartEngineOnConfigChange (static pure predicate)

    func testRestartWhenIntendedAndNotInterrupted() {
        // Normal state: app is playing and no interruption is active.
        // The engine SHOULD restart to rebind to the new route/format.
        XCTAssertTrue(
            AudioOutput.shouldRestartEngineOnConfigChange(intendedToRun: true, isInterrupted: false),
            "Engine must restart when intendedToRun=true and isInterrupted=false"
        )
    }

    func testNoRestartWhenNotIntended() {
        // Engine was explicitly stopped (user stop / CarPlay disconnect).
        // A route change after stop must NOT restart the engine.
        XCTAssertFalse(
            AudioOutput.shouldRestartEngineOnConfigChange(intendedToRun: false, isInterrupted: false),
            "Engine must NOT restart when intendedToRun=false"
        )
    }

    func testNoRestartWhenInterruptedAndIntended() {
        // The 46u case: app is riding out a Siri/phone-call interruption
        // (intendedToRun=true, VLC alive), Siri fires a route/format change.
        // Engine must NOT restart — this was the audio-leak bug.
        XCTAssertFalse(
            AudioOutput.shouldRestartEngineOnConfigChange(intendedToRun: true, isInterrupted: true),
            "Engine must NOT restart during an active interruption (46u fix)"
        )
    }

    func testNoRestartWhenInterruptedAndNotIntended() {
        // Degenerate combination: interrupted AND idle.
        // Engine must still not restart.
        XCTAssertFalse(
            AudioOutput.shouldRestartEngineOnConfigChange(intendedToRun: false, isInterrupted: true),
            "Engine must NOT restart when both intendedToRun=false and isInterrupted=true"
        )
    }

    // NOTE (beads_mobilemusic-cpr kickback, Block 2): CarPlay reconnect-resume
    // now gates on AudioOutput.shared.isInterrupted (exposed read-only)
    // instead of AudioPlayerService's interruptionBeganCount/
    // interruptionEndedCount — see the comment on `isInterrupted` in
    // AudioOutput.swift and on `attemptCarPlayReconnectResume()` in
    // CarPlayTemplateManager.swift for why. Deliberately NOT unit-tested at
    // the instance level here: touching `AudioOutput.shared` for the first
    // time constructs the real AVAudioEngine, which reliably deadlocks the
    // simulator's CoreAudio RPC in this test target (observed: "RPC timeout.
    // Apparently deadlocked" on every one of the 4 candidate tests, each
    // requiring an app-under-test relaunch). The three mutators it composes
    // (isInterrupted = true/false) are single-line assignments with no
    // branching logic to validate beyond the type checker.
}
