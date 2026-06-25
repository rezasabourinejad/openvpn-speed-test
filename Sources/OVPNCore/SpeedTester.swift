import Foundation

/// Measures real download / upload throughput against Cloudflare's speed endpoint.
/// Runs *through* the current default route — i.e. through the OpenVPN tunnel once
/// `OpenVPNRunner` has brought it up.
///
/// Each parallel stream pulls/pushes fixed-size chunks back-to-back for the whole
/// window so the pipe stays saturated (Cloudflare caps a single `__down` request at
/// <100 MB, and at high speed one chunk finishes in well under a second). Byte counting
/// happens in a URLSession delegate so it stays cheap at gigabit rates — iterating
/// `AsyncBytes` byte-by-byte would bottleneck on CPU and under-report the real speed.
public final class SpeedTester {
    public struct Config: Sendable {
        public var downloadSeconds: Double
        public var uploadSeconds: Double
        public var downloadChunkBytes: Int     // per request; must stay < 100_000_000
        public var uploadChunkBytes: Int
        public var parallelStreams: Int

        public init(downloadSeconds: Double = 6, uploadSeconds: Double = 6,
                    downloadChunkBytes: Int = 50_000_000, uploadChunkBytes: Int = 25_000_000,
                    parallelStreams: Int = 6) {
            self.downloadSeconds = downloadSeconds
            self.uploadSeconds = uploadSeconds
            self.downloadChunkBytes = downloadChunkBytes
            self.uploadChunkBytes = uploadChunkBytes
            self.parallelStreams = parallelStreams
        }
    }

    public var config: Config
    private let host = "https://speed.cloudflare.com"
    /// Live progress callback: (currentMbps, phase), ~5×/sec.
    public var onProgress: (@Sendable (Double, Phase) -> Void)?
    public var debugErrors = false

    public enum Phase: Sendable { case download, upload }

    public init(config: Config = Config()) {
        self.config = config
    }

    public func run() async -> SpeedResult {
        let down = await measureDownload()
        let up = await measureUpload()
        return SpeedResult(downloadMbps: down, uploadMbps: up)
    }

    public func measureDownload() async -> Double {
        let url = URL(string: "\(host)/__down?bytes=\(config.downloadChunkBytes)")!
        return await measurePhase(seconds: config.downloadSeconds, phase: .download) { session in
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            return session.dataTask(with: req)
        }
    }

    public func measureUpload() async -> Double {
        let url = URL(string: "\(host)/__up")!
        let payload = Data(count: config.uploadChunkBytes)
        return await measurePhase(seconds: config.uploadSeconds, phase: .upload) { session in
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            return session.uploadTask(with: req, from: payload)
        }
    }

    /// Run N parallel workers that issue chunk requests back-to-back until the deadline,
    /// then compute Mbps from the bytes moved during the steady-state window (post warm-up).
    private func measurePhase(seconds: Double, phase: Phase,
                              makeTask: @escaping (URLSession) -> URLSessionTask?) async -> Double {
        let counter = SpeedCounter()
        let delegate = SpeedDelegate(counter: counter)
        delegate.debug = debugErrors
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }

        let deadline = Date().addingTimeInterval(seconds)

        // Workers keep the pipe full; they run independently of the measurement clock.
        let workers = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<config.parallelStreams {
                    group.addTask {
                        while Date() < deadline {
                            guard let task = makeTask(session) else { break }
                            await delegate.run(task)
                        }
                    }
                }
                await group.waitForAll()
            }
        }

        // Measurement: ignore a short warm-up, then sample until the deadline.
        let warmup = Swift.min(1.0, seconds * 0.2)
        try? await Task.sleep(nanoseconds: UInt64(warmup * 1e9))
        let startBytes = counter.total
        let start = Date()

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0 {
                onProgress?(Double(counter.total - startBytes) * 8.0 / elapsed / 1_000_000.0, phase)
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        let bytes = counter.total - startBytes
        workers.cancel()
        guard elapsed > 0 else { return 0 }
        return Double(bytes) * 8.0 / elapsed / 1_000_000.0
    }

    private func makeSession(delegate: SpeedDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }
}

/// Thread-safe byte accumulator.
final class SpeedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
    func add(_ n: Int) { lock.lock(); _total += n; lock.unlock() }
}

/// Counts bytes (download: `didReceive data`, upload: `didSendBodyData`) and resolves a
/// per-task continuation on completion so workers can chain chunks back-to-back.
final class SpeedDelegate: NSObject, URLSessionDataDelegate {
    let counter: SpeedCounter
    var debug = false
    private let lock = NSLock()
    private var conts: [Int: CheckedContinuation<Void, Never>] = [:]

    init(counter: SpeedCounter) { self.counter = counter }

    /// Resume `task` and suspend until it finishes (or errors).
    func run(_ task: URLSessionTask) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            conts[task.taskIdentifier] = cont
            lock.unlock()
            task.resume()
        }
    }

    private func finish(_ id: Int) {
        lock.lock()
        let cont = conts.removeValue(forKey: id)
        lock.unlock()
        cont?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        counter.add(Int(bytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if debug, let error, (error as NSError).code != NSURLErrorCancelled {
            FileHandle.standardError.write("  [speed] task error: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
        finish(task.taskIdentifier)
    }
}
