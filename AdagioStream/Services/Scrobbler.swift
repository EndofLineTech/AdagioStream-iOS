// Scrobbler.swift
//
// 65x.1: Scrobble state + fire helpers extracted from AudioPlayerService.
//
// Owns:
//   - submissionSent: one-per-track guard ensuring exactly one submission
//     scrobble fires per track play.
//   - shouldSubmit(elapsed:duration:): pure threshold function (Last.fm rules).
//   - fireNowPlaying(trackID:via:): fires the "now playing" scrobble at track start.
//   - fireSubmissionIfNeeded(trackID:via:): fires the submission scrobble once when
//     the threshold is reached.
//   - reset(): called by AudioPlayerService at the start of every new library track.
//
// AudioPlayerService keeps a forwarding static `scrobbleShouldSubmit(elapsed:duration:)`
// so existing call sites (including ScrobbleTests.swift) remain unchanged.

import Foundation

@MainActor
final class Scrobbler {

    // MARK: - Threshold (pure, nonisolated for test access without MainActor)

    /// Standard Last.fm scrobble submission rule:
    ///
    /// Submit when the track has been played for **≥ 4 minutes** OR **≥ 50%
    /// of its duration**, whichever comes first.
    ///
    /// - If `duration` is nil or zero (unknown): falls back to the 4-minute rule only.
    /// - Returns `true` when the threshold is reached, `false` otherwise.
    ///
    /// `nonisolated` so tests and `AudioPlayerService.scrobbleShouldSubmit`
    /// can call it from non-MainActor contexts.
    nonisolated static func shouldSubmit(elapsed: Double, duration: Double?) -> Bool {
        if elapsed >= 240 { return true }           // ≥ 4 minutes
        guard let dur = duration, dur > 0 else { return false }
        return elapsed >= dur * 0.5                 // ≥ 50% of duration
    }

    // MARK: - Per-track submission guard

    /// Whether the submission scrobble has already been fired for the
    /// currently-playing library track.  Reset to `false` by `reset()` at
    /// the start of every new track.  Once `true` it stays `true` for the
    /// lifetime of the track play — a second call is never sent even if
    /// `syncState` ticks several more times past the threshold.
    private(set) var submissionSent: Bool = false

    // MARK: - Track lifecycle

    /// Resets the per-track submission guard.  Call at the start of every
    /// new library track play (i.e., in `AudioPlayerService.startLibraryTrack`).
    func reset() {
        submissionSent = false
    }

    // MARK: - Fire helpers

    /// Fires a now-playing (`submission=false`) scrobble for the given track.
    ///
    /// Fire-and-forget: errors are logged at debug level and swallowed so
    /// they can never disrupt or stop playback.
    func fireNowPlaying(trackID: String, via api: NavidromeAPI) {
        Task {
            do {
                try await api.scrobble(id: trackID, submission: false)
                DebugLogger.shared.log("Scrobble now-playing sent: trackID=\(trackID)", category: .player)
            } catch {
                DebugLogger.shared.log("Scrobble now-playing FAILED (swallowed): \(error.localizedDescription)", category: .player)
            }
        }
    }

    /// Fires a submission (`submission=true`) scrobble for the given track, once.
    ///
    /// Guards on `submissionSent` to ensure exactly one submission per track
    /// play.  Marks the guard immediately before the async call so a second
    /// tick of `syncState` arriving before the network round-trip cannot
    /// enqueue a duplicate.
    func fireSubmissionIfNeeded(trackID: String, via api: NavidromeAPI) {
        guard !submissionSent else { return }
        submissionSent = true
        let timeMs = Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            do {
                try await api.scrobble(id: trackID, submission: true, time: timeMs)
                DebugLogger.shared.log("Scrobble submission sent: trackID=\(trackID)", category: .player)
            } catch {
                DebugLogger.shared.log("Scrobble submission FAILED (swallowed): \(error.localizedDescription)", category: .player)
            }
        }
    }
}
