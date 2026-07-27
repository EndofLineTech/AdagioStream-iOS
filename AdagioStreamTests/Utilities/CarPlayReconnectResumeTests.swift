// CarPlayReconnectResumeTests.swift
//
// Truth-table tests for beads_mobilemusic-cpr: the pure decision function
// behind the user-configurable CarPlay-reconnect resume feature.
//
// CarPlayTemplateManager.carPlayResumeDecision(...) is framework-free (no
// CarPlay/AVFoundation/ProviderManager types), so every combination of
// preference × target-resolution × already-playing × interruption ×
// one-shot is exercised here without a live CarPlay connection.
//
// Gated #if os(iOS) because CarPlayTemplateManager lives under CarPlay/,
// which is excluded from the tvOS target.

#if os(iOS)
import XCTest
@testable import AdagioStream

final class CarPlayReconnectResumeTests: XCTestCase {

    private typealias Decision = CarPlayTemplateManager

    // MARK: - Off: always skips regardless of every other input

    func testOffSkipsEvenWhenTargetExistsAndNothingElseBlocks() {
        let outcome = Decision.carPlayResumeDecision(
            preference: .off,
            targetExists: true,
            somethingAlreadyPlaying: false,
            interruptionInFlight: false,
            alreadyAttemptedThisConnection: false
        )
        XCTAssertEqual(outcome, .skip)
    }

    func testOffSkipsRegardlessOfInterruptionOrPlayingState() {
        for somethingPlaying in [true, false] {
            for interrupted in [true, false] {
                let outcome = Decision.carPlayResumeDecision(
                    preference: .off,
                    targetExists: true,
                    somethingAlreadyPlaying: somethingPlaying,
                    interruptionInFlight: interrupted,
                    alreadyAttemptedThisConnection: false
                )
                XCTAssertEqual(outcome, .skip)
            }
        }
    }

    // MARK: - lastPlayed: exists / missing

    func testLastPlayedPlaysWhenTargetExistsAndNothingBlocks() {
        let outcome = Decision.carPlayResumeDecision(
            preference: .lastPlayed,
            targetExists: true,
            somethingAlreadyPlaying: false,
            interruptionInFlight: false,
            alreadyAttemptedThisConnection: false
        )
        XCTAssertEqual(outcome, .play)
    }

    func testLastPlayedSkipsWhenTargetMissing() {
        // Acceptance criterion 4's "no error loop" applies to specific,
        // but lastPlayed must be equally silent if the last-played channel
        // disappeared (provider removed, channel deleted).
        let outcome = Decision.carPlayResumeDecision(
            preference: .lastPlayed,
            targetExists: false,
            somethingAlreadyPlaying: false,
            interruptionInFlight: false,
            alreadyAttemptedThisConnection: false
        )
        XCTAssertEqual(outcome, .skip)
    }

    // MARK: - specific: exists / missing (acceptance criterion 4)

    func testSpecificPlaysWhenTargetExists() {
        let outcome = Decision.carPlayResumeDecision(
            preference: .specific,
            targetExists: true,
            somethingAlreadyPlaying: false,
            interruptionInFlight: false,
            alreadyAttemptedThisConnection: false
        )
        XCTAssertEqual(outcome, .play)
    }

    func testSpecificSkipsSilentlyWhenTargetDeleted() {
        let outcome = Decision.carPlayResumeDecision(
            preference: .specific,
            targetExists: false,
            somethingAlreadyPlaying: false,
            interruptionInFlight: false,
            alreadyAttemptedThisConnection: false
        )
        XCTAssertEqual(outcome, .skip)
    }

    // MARK: - Already playing: never stomp existing playback

    func testSkipsWhenSomethingAlreadyPlayingEvenIfTargetExists() {
        for preference: CarPlayReconnectResume in [.lastPlayed, .specific] {
            let outcome = Decision.carPlayResumeDecision(
                preference: preference,
                targetExists: true,
                somethingAlreadyPlaying: true,
                interruptionInFlight: false,
                alreadyAttemptedThisConnection: false
            )
            XCTAssertEqual(outcome, .skip, "\(preference) should not stomp existing playback")
        }
    }

    // MARK: - Interruption gate (bug 46u): never play while interrupted

    func testSkipsWhileInterruptionInFlightEvenIfTargetExists() {
        for preference: CarPlayReconnectResume in [.lastPlayed, .specific] {
            let outcome = Decision.carPlayResumeDecision(
                preference: preference,
                targetExists: true,
                somethingAlreadyPlaying: false,
                interruptionInFlight: true,
                alreadyAttemptedThisConnection: false
            )
            XCTAssertEqual(outcome, .skip, "\(preference) must respect the interruption gate")
        }
    }

    // MARK: - One-shot per connection

    func testSkipsWhenAlreadyAttemptedEvenIfTargetExistsAndNothingElseBlocks() {
        for preference: CarPlayReconnectResume in [.lastPlayed, .specific] {
            let outcome = Decision.carPlayResumeDecision(
                preference: preference,
                targetExists: true,
                somethingAlreadyPlaying: false,
                interruptionInFlight: false,
                alreadyAttemptedThisConnection: true
            )
            XCTAssertEqual(outcome, .skip, "\(preference) must not fire a second time in the same connection")
        }
    }

    // MARK: - Full truth table sweep

    /// Every combination of the five boolean/enum axes. `.play` is the
    /// outcome for exactly one row per non-off preference: target exists,
    /// nothing already playing, no interruption, not already attempted.
    /// Every other combination must be `.skip`.
    func testFullTruthTable() {
        for preference: CarPlayReconnectResume in CarPlayReconnectResume.allCases {
            for targetExists in [true, false] {
                for somethingAlreadyPlaying in [true, false] {
                    for interruptionInFlight in [true, false] {
                        for alreadyAttempted in [true, false] {
                            let outcome = Decision.carPlayResumeDecision(
                                preference: preference,
                                targetExists: targetExists,
                                somethingAlreadyPlaying: somethingAlreadyPlaying,
                                interruptionInFlight: interruptionInFlight,
                                alreadyAttemptedThisConnection: alreadyAttempted
                            )
                            let expectedPlay = preference != .off
                                && targetExists
                                && !somethingAlreadyPlaying
                                && !interruptionInFlight
                                && !alreadyAttempted
                            XCTAssertEqual(
                                outcome,
                                expectedPlay ? .play : .skip,
                                "preference=\(preference) targetExists=\(targetExists) "
                                    + "somethingAlreadyPlaying=\(somethingAlreadyPlaying) "
                                    + "interruptionInFlight=\(interruptionInFlight) "
                                    + "alreadyAttempted=\(alreadyAttempted)"
                            )
                        }
                    }
                }
            }
        }
    }
}
#endif
