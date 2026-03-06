import Foundation

/// Downloads stream data during audio interruptions so playback can resume
/// from where it left off instead of rejoining live.
///
/// Pure capture utility — AudioPlayerService manages playback and chaining.
/// Each startCapture creates a new temp file. The caller owns returned URLs
/// and is responsible for deleting them after use.
@MainActor
final class TimeShiftBufferService: NSObject, ObservableObject {
    static let shared = TimeShiftBufferService()

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var isTimeShifted: Bool = false
    @Published private(set) var capturedDuration: TimeInterval = 0

    private let log = DebugLogger.shared
    private let writeQueue = DispatchQueue(label: "com.adagiostream.timeshift.write")

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var bufferFileURL: URL?
    private var capturedBytes: Int = 0
    private var captureStartTime: Date?
    private var estimatedBitrateBytes: Double = 0 // bytes per second
    private var durationTimer: Timer?

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Begin capturing stream data for the given channel's URL.
    /// Can be called while already capturing — stops the old capture first
    /// (without deleting its file, which the caller may still be using).
    func startCapture(for channel: Channel, estimatedBitrateKbps: Double = 0) {
        // If already capturing, tear down the old session but don't delete
        // the old file — the caller (AudioPlayerService) owns it.
        if isCapturing {
            log.log("Restarting capture (was already capturing)", category: .timeShift)
            stopSession()
        }

        log.log("Starting time-shift capture for \"\(channel.name)\"", category: .timeShift)

        // Prepare temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "timeshift-\(UUID().uuidString).ts"
        let fileURL = tempDir.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            log.log("Failed to create buffer file at \(fileURL.path)", category: .timeShift)
            return
        }

        bufferFileURL = fileURL
        fileHandle = handle
        capturedBytes = 0
        captureStartTime = Date()
        estimatedBitrateBytes = estimatedBitrateKbps * 1000 / 8 // kbps -> bytes/sec

        // Create a dedicated URLSession for the capture
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Constants.TimeShift.maxDuration + 10
        config.httpAdditionalHeaders = ["User-Agent": "AdagioStream/1.0"]
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = writeQueue
        session = URLSession(configuration: config, delegate: DataDelegate(fileHandle: handle, service: self), delegateQueue: delegateQueue)

        let request = URLRequest(url: channel.streamURL)
        dataTask = session?.dataTask(with: request)
        dataTask?.resume()

        isCapturing = true
        isTimeShifted = true
        capturedDuration = 0

        // Timer to update estimated duration
        durationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateEstimatedDuration()
            }
        }

        log.log("Capture started: file=\(fileName), bitrateEstimate=\(Int(estimatedBitrateKbps))kbps", category: .timeShift)
    }

    /// Stop capturing and return the buffer file URL if enough data was captured.
    /// Does NOT clear isTimeShifted — caller decides when time-shift mode ends.
    func stopCapture() -> URL? {
        guard isCapturing else {
            log.log("stopCapture ignored: not capturing", category: .timeShift)
            return nil
        }

        log.log("Stopping capture: \(capturedBytes) bytes, ~\(String(format: "%.1f", capturedDuration))s", category: .timeShift)
        stopSession()

        if capturedBytes >= Constants.TimeShift.minBytes, let url = bufferFileURL {
            log.log("Buffer ready: \(capturedBytes) bytes at \(url.lastPathComponent)", category: .timeShift)
            bufferFileURL = nil  // Caller owns this URL now
            return url
        } else {
            log.log("Buffer too small (\(capturedBytes) bytes < \(Constants.TimeShift.minBytes)), discarding", category: .timeShift)
            if let url = bufferFileURL {
                try? FileManager.default.removeItem(at: url)
                bufferFileURL = nil
            }
            return nil
        }
    }

    /// Skip buffered content and go straight to live. Cancels any active
    /// capture and clears time-shift state.
    func goLive() {
        log.log("goLive: isCapturing=\(isCapturing)", category: .timeShift)
        stopSession()
        cleanupFile()
        resetState()
    }

    /// Discard any captured data and return to idle.
    func cancelAndCleanup() {
        log.log("cancelAndCleanup: isCapturing=\(isCapturing)", category: .timeShift)
        stopSession()
        cleanupFile()
        resetState()
    }

    /// Delete a buffer file that the caller is done with.
    func deleteBufferFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func stopSession() {
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        durationTimer?.invalidate()
        durationTimer = nil
        writeQueue.sync {
            try? self.fileHandle?.close()
        }
        fileHandle = nil
        isCapturing = false
        capturedBytes = 0
        captureStartTime = nil
        estimatedBitrateBytes = 0
    }

    private func resetState() {
        isCapturing = false
        isTimeShifted = false
        capturedDuration = 0
        capturedBytes = 0
        captureStartTime = nil
        estimatedBitrateBytes = 0
    }

    private func cleanupFile() {
        if let url = bufferFileURL {
            try? FileManager.default.removeItem(at: url)
            bufferFileURL = nil
        }
    }

    private func updateEstimatedDuration() {
        guard isCapturing, let start = captureStartTime else { return }

        if estimatedBitrateBytes > 0 {
            capturedDuration = Double(capturedBytes) / estimatedBitrateBytes
        } else {
            capturedDuration = Date().timeIntervalSince(start)
        }

        if capturedDuration >= Constants.TimeShift.maxDuration {
            log.log("Max time-shift duration reached (\(Int(Constants.TimeShift.maxDuration))s), stopping capture", category: .timeShift)
            _ = stopCapture()
        }
    }

    /// Called from DataDelegate on background queue — updates byte count.
    fileprivate func didReceiveBytes(_ count: Int) {
        capturedBytes += count
    }

    /// Called from DataDelegate on background queue — handles completion.
    fileprivate func didCompleteDownload(error: Error?) {
        if let error = error as? NSError, error.code != NSURLErrorCancelled {
            log.log("Time-shift download error: \(error.localizedDescription)", category: .timeShift)
        }
        if isCapturing {
            log.log("Download completed/errored during capture, stopping", category: .timeShift)
            _ = stopCapture()
        }
    }
}

// MARK: - URLSession Data Delegate

/// Handles URLSession callbacks on the writeQueue, writing data to the
/// file handle directly, then notifying the MainActor service of byte counts.
private final class DataDelegate: NSObject, URLSessionDataDelegate {
    private let fileHandle: FileHandle
    private weak var service: TimeShiftBufferService?

    init(fileHandle: FileHandle, service: TimeShiftBufferService) {
        self.fileHandle = fileHandle
        self.service = service
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        fileHandle.write(data)
        let count = data.count
        Task { @MainActor [weak service] in
            service?.didReceiveBytes(count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak service] in
            service?.didCompleteDownload(error: error)
        }
    }
}
