//
//  CallStateDiagnostics.swift
//  AdagioStream
//
//  TEMPORARY diagnostic — TestFlight only.  See beads_mobilemusic-lfn.
//
//  Observes system call state via CallKit so we can confirm whether a phone
//  call is actually active when AudioPlayerService resumes from an audio
//  interruption (the CarPlay "music resumed during a Siri call" report).  The
//  AVAudioSession signals alone could not answer that question.
//
//  ⚠️ CallKit is an App Store risk in the China region, where this app ships.
//  EVERYTHING here is gated behind the DIAG_CALLKIT compilation condition
//  (set per-config in project.yml).  It must NOT reach the App Store: drop the
//  flag in project.yml before any production release.  See the no-CallKit
//  project memory and the cleanup bead that blocks release.
//

#if DIAG_CALLKIT
import CallKit
import Foundation

@MainActor
final class CallStateDiagnostics: NSObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    private let log = DebugLogger.shared

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
        log.log("CallStateDiagnostics active (DIAG_CALLKIT) — CallKit observer installed", category: .interruption)
    }

    /// One-line summary of the current calls, for embedding in other log lines
    /// at the moments that matter (interruption began/ended, post-resume probe).
    nonisolated func summary() -> String {
        let calls = observer.calls
        if calls.isEmpty { return "noCalls" }
        return calls.map { c in
            let connecting = !c.hasConnected && !c.hasEnded
            return "call(out=\(c.isOutgoing),connecting=\(connecting),connected=\(c.hasConnected),onHold=\(c.isOnHold),ended=\(c.hasEnded))"
        }.joined(separator: " | ")
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        DebugLogger.shared.log("CallChanged: uuid=\(call.uuid.uuidString.prefix(8)) outgoing=\(call.isOutgoing) connected=\(call.hasConnected) onHold=\(call.isOnHold) ended=\(call.hasEnded)", category: .interruption)
    }
}
#endif
