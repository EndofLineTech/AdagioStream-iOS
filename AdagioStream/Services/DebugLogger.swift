import Foundation

/// Persistent file-based logger for debugging CarPlay and player issues.
/// Logs are written to the app's documents directory and can be exported via the share sheet.
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    /// Controls whether log messages are written. Toggled via Settings.
    var isEnabled: Bool {
        get { queue.sync { _isEnabled } }
        set { queue.sync { _isEnabled = newValue } }
    }
    private var _isEnabled = false

    private let queue = DispatchQueue(label: "com.adagiostream.debuglogger")
    private let maxFileSize: UInt64 = 2 * 1024 * 1024 // 2 MB
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("adagiostream-debug.log")
    }

    private var previousLogFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("adagiostream-debug-prev.log")
    }

    private init() {}

    // MARK: - Public API

    func log(_ message: String, category: Category = .general, file: String = #fileID, line: Int = #line) {
        guard isEnabled else { return }
        let timestamp = dateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let entry = "[\(timestamp)] [\(category.rawValue)] [\(fileName):\(line)] \(message)\n"

        queue.async { [self] in
            rotateIfNeeded()
            appendToFile(entry)
        }
    }

    func logFileSize() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64 else { return "0 KB" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    func clearLogs() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: logFileURL)
            try? FileManager.default.removeItem(at: previousLogFileURL)
        }
    }

    // MARK: - Categories

    enum Category: String {
        case general = "GENERAL"
        case player = "PLAYER"
        case audioSession = "AUDIO"
        case carplay = "CARPLAY"
        case vlcState = "VLC"
        case interruption = "INTERRUPT"
        case remoteCommand = "REMOTE"
        case nowPlaying = "NOWPLAY"
        case call = "CALL"
    }

    // MARK: - Private

    private func appendToFile(_ entry: String) {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            // Write a header
            let header = "=== AdagioStream Debug Log ===\n\n"
            try? header.write(to: url, atomically: false, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = entry.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64, size > maxFileSize else { return }

        // Keep one previous log for context
        try? FileManager.default.removeItem(at: previousLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: previousLogFileURL)
    }
}
