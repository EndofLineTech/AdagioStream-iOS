import Foundation

/// Captures the moment of an otherwise-silent termination so the field log
/// makes the unrecoverable CarPlay/Siri failure unambiguous (bd a14).
///
/// The reported symptom — "it crashes on CarPlay but there's no crash dump on
/// the iPhone" — is consistent with either an uncaught NSException (e.g. from
/// CoreAudio/AVAudioEngine) or a watchdog/jetsam kill. Two capture paths:
///
///  - Uncaught Obj-C/Swift exceptions → `NSSetUncaughtExceptionHandler`. Runs
///    in normal context, so it can use `DebugLogger` and record the name,
///    reason, and call stack synchronously before the process dies.
///  - Fatal POSIX signals (SIGSEGV/SIGABRT/…) → `sigaction` handlers that write
///    a pre-rendered marker with async-signal-safe `write(2)` to a pre-opened
///    fd, then `SA_RESETHAND` restores the default disposition and we re-raise
///    so the OS still produces its standard crash report.
///
/// Diagnostic-only: nothing here changes playback behavior.
enum CrashReporter {
    private static var logFD: Int32 = -1

    // Pre-rendered, immortal marker bytes per signal. Allocated once at install
    // time (normal context) so the signal handler only needs write(2).
    private static var markerSigs: [Int32] = []
    private static var markerPtrs: [UnsafePointer<UInt8>] = []
    private static var markerLens: [Int] = []

    private static let fatalSignals: [(Int32, String)] = [
        (SIGABRT, "SIGABRT"), (SIGILL, "SIGILL"), (SIGSEGV, "SIGSEGV"),
        (SIGFPE, "SIGFPE"), (SIGBUS, "SIGBUS"), (SIGTRAP, "SIGTRAP"),
    ]

    static func install() {
        let path = DebugLogger.shared.logFileURL.path
        logFD = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

        for (sig, name) in fatalSignals {
            let text = "\n=== FATAL SIGNAL \(name) — AdagioStream terminating ===\n"
            let bytes = Array(text.utf8)
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            buf.initialize(from: bytes, count: bytes.count)
            markerSigs.append(sig)
            markerPtrs.append(UnsafePointer(buf))
            markerLens.append(bytes.count)

            var action = sigaction()
            action.sa_flags = SA_RESETHAND
            action.__sigaction_u.__sa_handler = CrashReporter.handle
            sigaction(sig, &action, nil)
        }

        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "nil"
            let stack = exception.callStackSymbols.prefix(24).joined(separator: " | ")
            DebugLogger.shared.logCritical("UNCAUGHT EXCEPTION \(name): \(reason) :: \(stack)")
        }
    }

    // @convention(c): no captured context. Reads only trivial global storage
    // and calls write(2)/fsync(2)/raise(2) — all async-signal-safe. The linear
    // scan over fixed Int32/pointer/Int arrays avoids any ARC or hashing.
    private static let handle: @convention(c) (Int32) -> Void = { sig in
        if logFD >= 0 {
            var i = 0
            let count = markerSigs.count
            while i < count {
                if markerSigs[i] == sig {
                    _ = write(logFD, markerPtrs[i], markerLens[i])
                    fsync(logFD)
                    break
                }
                i += 1
            }
        }
        // SA_RESETHAND restored the default handler; re-raise so the OS still
        // writes its normal crash report.
        raise(sig)
    }
}
