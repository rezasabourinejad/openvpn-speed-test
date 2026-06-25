import Foundation
import Network

/// Measures real round-trip latency + jitter to a server by timing TCP handshakes.
///
/// We probe with TCP because VPN endpoints rate-limit / drop ICMP, producing fake
/// packet-loss. A TCP SYN→SYN-ACK is exactly one network round-trip and is answered
/// reliably on port 443, so it is a clean, stable latency signal for ranking servers.
public struct LatencyTester {
    public var samplesPerHost: Int
    public var perProbeTimeout: Double      // seconds
    public var maxConcurrentHosts: Int
    /// A handshake slower than `min + retransmitFloorMs` (and at least `retransmitMultiplier×`
    /// the fastest sample) is treated as a lost packet that got retransmitted (~1s TCP RTO),
    /// not as a real latency sample. It counts toward loss%, not toward ping/jitter.
    public var retransmitFloorMs: Double
    public var retransmitMultiplier: Double

    public init(samplesPerHost: Int = 8, perProbeTimeout: Double = 1.3, maxConcurrentHosts: Int = 40,
                retransmitFloorMs: Double = 250, retransmitMultiplier: Double = 2.5) {
        self.samplesPerHost = samplesPerHost
        self.perProbeTimeout = perProbeTimeout
        self.maxConcurrentHosts = maxConcurrentHosts
        self.retransmitFloorMs = retransmitFloorMs
        self.retransmitMultiplier = retransmitMultiplier
    }

    /// One TCP handshake; returns RTT in ms, or nil on timeout/failure.
    public func probe(host: String, port: UInt16) async -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let params = NWParameters.tcp
        // We only care about reaching .ready; no need to keep the socket around.
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let queue = DispatchQueue(label: "latency.probe")
        let start = DispatchTime.now()

        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let state = ProbeState()
            @Sendable func finish(_ value: Double?) {
                guard state.tryFinish() else { return }
                conn.stateUpdateHandler = nil
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    finish(Double(ns) / 1_000_000.0)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + perProbeTimeout) { finish(nil) }
        }
    }

    /// Sequential samples to one host → a LatencyResult (jitter needs ordered samples).
    public func measure(host: String, port: UInt16) async -> LatencyResult {
        var raw: [Double] = []
        for _ in 0..<samplesPerHost {
            if let rtt = await probe(host: host, port: port) {
                raw.append(rtt)
            }
            // tiny gap so back-to-back handshakes don't get coalesced/rate-limited
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }
        // Drop retransmit outliers — they're packet loss, not latency. Counting them as
        // ~1000ms samples would wreck jitter/max and misrank a perfectly good server.
        let good = filterRetransmits(raw)
        return LatencyResult(host: host, port: port, samples: good, attempts: samplesPerHost)
    }

    /// Keep only samples consistent with the link's real RTT; reclassify the rest as loss.
    func filterRetransmits(_ raw: [Double]) -> [Double] {
        guard let base = raw.min() else { return [] }
        let cutoff = Swift.max(base + retransmitFloorMs, base * retransmitMultiplier)
        return raw.filter { $0 <= cutoff }
    }

    /// Measure many profiles in parallel (bounded concurrency).
    /// `onResult` is called as each one finishes, for live UI updates.
    public func measureAll(
        _ profiles: [OVPNProfile],
        onResult: @escaping @Sendable (OVPNProfile, LatencyResult) -> Void = { _, _ in }
    ) async -> [String: LatencyResult] {
        var results: [String: LatencyResult] = [:]
        let limit = max(1, maxConcurrentHosts)

        await withTaskGroup(of: (String, LatencyResult)?.self) { group in
            var index = 0
            var running = 0

            func submit() {
                guard index < profiles.count else { return }
                let profile = profiles[index]
                index += 1
                running += 1
                guard let host = profile.host else {
                    group.addTask { (profile.id, LatencyResult(host: "-", port: 0, samples: [], attempts: 0)) }
                    return
                }
                let port = profile.latencyPort
                group.addTask {
                    let r = await self.measure(host: host, port: port)
                    onResult(profile, r)
                    return (profile.id, r)
                }
            }

            while running < limit && index < profiles.count { submit() }
            while let finished = await group.next() {
                running -= 1
                if let (id, r) = finished { results[id] = r }
                if index < profiles.count { submit() }
            }
        }
        return results
    }
}

/// Tiny thread-safe one-shot latch so a probe resolves its continuation exactly once.
final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
