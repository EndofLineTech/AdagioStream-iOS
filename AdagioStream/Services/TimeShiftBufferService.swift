import Foundation

/// Downloads stream data during audio interruptions so playback can resume
/// from where it left off instead of rejoining live.
///
/// Uses URLSession to capture TS segments into a temp file while VLC is stopped.
/// When the interruption ends, AudioPlayerService plays the buffered file first,
/// then transitions back to the live stream.
@MainActor
final class TimeShiftBufferService: NSObject, ObservableObject {
    static let shared = TimeShiftBufferService()

    enum State: String {
        case idle
        case capturing
        case readyToPlay
        case playingBuffer
        case transitioningToLive
    }

    @Published private(set) var state: State = .idle
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
    func startCapture(for channel: Channel, estimatedBitrateKbps: Double = 0) {
        guard state == .idle else {
            log.log("startCapture ignored: state=\(state.rawValue)", category: .timeShift)
            return
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

        state = .capturing
        isTimeShifted = true
        capturedDuration = 0

        // Timer to update estimated duration
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateEstimatedDuration()
            }
        }

        log.log("Capture started: file=\(fileName), bitrateEstimate=\(Int(estimatedBitrateKbps))kbps", category: .timeShift)
    }

    /// Stop capturing and return the buffer file URL if enough data was captured.
    func stopCapture() -> URL? {
        guard state == .capturing else {
            log.log("stopCapture ignored: state=\(state.rawValue)", category: .timeShift)
            return nil
        }

        log.log("Stopping capture: \(capturedBytes) bytes, ~\(String(format: "%.1f", capturedDuration))s", category: .timeShift)

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

        if capturedBytes >= Constants.TimeShift.minBytes, let url = bufferFileURL {
            state = .readyToPlay
            log.log("Buffer ready: \(capturedBytes) bytes at \(url.lastPathComponent)", category: .timeShift)
            return url
        } else {
            log.log("Buffer too small (\(capturedBytes) bytes < \(Constants.TimeShift.minBytes)), discarding", category: .timeShift)
            cleanupFile()
            reset()
            return nil
        }
    }

    /// Called when AudioPlayerService starts playing the buffered file.
    func bufferPlaybackStarted() {
        guard state == .readyToPlay else { return }
        state = .playingBuffer
        log.log("Buffer playback started", category: .timeShift)
    }

    /// Called when VLC finishes playing the buffered file.
    func bufferPlaybackDidEnd() {
        guard state == .playingBuffer else { return }
        state = .transitioningToLive
        log.log("Buffer playback ended, transitioning to live", category: .timeShift)
    }

    /// Called when the live stream has resumed after buffer playback.
    func transitionToLiveComplete() {
        log.log("Transition to live complete", category: .timeShift)
        cleanupFile()
        reset()
    }

    /// Skip buffered content and go straight to live.
    func goLive() {
        log.log("goLive: skipping buffer, state=\(state.rawValue)", category: .timeShift)
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
        cleanupFile()
        reset()
    }

    /// Discard any captured data and return to idle.
    func cancelAndCleanup() {
        log.log("cancelAndCleanup: state=\(state.rawValue)", category: .timeShift)
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
        cleanupFile()
        reset()
    }

    // MARK: - Private

    private func reset() {
        state = .idle
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
        guard state == .capturing, let start = captureStartTime else { return }

        if estimatedBitrateBytes > 0 {
            // Estimate from bytes and bitrate
            capturedDuration = Double(capturedBytes) / estimatedBitrateBytes
        } else {
            // Fallback: wall clock time (less accurate but good enough)
            capturedDuration = Date().timeIntervalSince(start)
        }

        // Cap at max duration
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
        if state == .capturing {
            log.log("Download completed/errored during capture, stopping", category: .timeShift)
            _ = stopCapture()
        }
    }
}

// MARK: - URLSession Data Delegate

/// Handles URLSession callbacks on the writeQueue, writing data to the
/// file handle directly, then notifying the MainActor service of byte counts.
private final class DataDelegate: NSObject, URLSessionDataDelegate {
    // Unowned to avoid retain cycle — the service owns the session which owns this delegate
    private let fileHandle: FileHandle
    private weak var service: TimeShiftBufferService?

    init(fileHandle: FileHandle, service: TimeShiftBufferService) {
        self.fileHandle = fileHandle
        self.service = service
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // This runs on writeQueue — file I/O is serialized
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
