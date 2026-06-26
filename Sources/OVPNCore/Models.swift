import Foundation

/// A parsed OpenVPN profile (.ovpn file).
public struct OVPNProfile: Identifiable, Hashable, Sendable {
    public var id: String { fileURL.path }
    public let fileURL: URL
    /// Display name — derived from the CN if present, otherwise the file name.
    public let name: String
    /// All `remote <host> <port>` entries, in file order.
    public let remotes: [Remote]
    /// "udp" or "tcp"
    public let proto: String

    public struct Remote: Hashable, Sendable {
        public let host: String
        public let port: UInt16
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public init(fileURL: URL, name: String, remotes: [Remote], proto: String) {
        self.fileURL = fileURL
        self.name = name
        self.remotes = remotes
        self.proto = proto
    }

    /// First remote host (servers in a Nord profile share one IP across ports).
    public var host: String? { remotes.first?.host }

    /// Provider grouping key derived from the profile name / CN, e.g.
    /// "de1208.nordvpn.com" → "nordvpn.com", "uk-london.expressvpn.com" → "expressvpn.com".
    /// Profiles from the same provider share one set of credentials by default.
    public var providerKey: String {
        var labels = name.lowercased().split(separator: ".").map(String.init)
        while let last = labels.last, ["udp", "tcp", "ovpn"].contains(last) { labels.removeLast() }
        if labels.count >= 2 { return labels.suffix(2).joined(separator: ".") }
        return labels.first ?? name.lowercased()
    }

    /// The TCP port we probe for latency.
    /// For tcp profiles we use the real remote port; for udp we fall back to 443,
    /// which every Nord node keeps open and answers cleanly (ICMP is rate-limited).
    public var latencyPort: UInt16 {
        if proto.lowercased() == "tcp", let p = remotes.first?.port { return p }
        return 443
    }
}

/// Result of the latency / jitter module.
public struct LatencyResult: Hashable, Sendable {
    public let host: String
    public let port: UInt16
    /// Successful round-trip times, in milliseconds, in sample order.
    public let samples: [Double]
    public let attempts: Int

    public init(host: String, port: UInt16, samples: [Double], attempts: Int) {
        self.host = host
        self.port = port
        self.samples = samples
        self.attempts = attempts
    }

    public var received: Int { samples.count }
    public var lossPct: Double {
        attempts == 0 ? 0 : Double(attempts - received) / Double(attempts) * 100
    }
    public var min: Double? { samples.min() }
    public var max: Double? { samples.max() }
    public var avg: Double? {
        samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
    }
    /// Median is more robust to the occasional handshake outlier.
    public var median: Double? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
    /// Jitter = mean absolute difference between consecutive samples (RFC 3550 style).
    public var jitter: Double? {
        guard samples.count >= 2 else { return nil }
        var total = 0.0
        for i in 1..<samples.count { total += Swift.abs(samples[i] - samples[i - 1]) }
        return total / Double(samples.count - 1)
    }
    public var stddev: Double? {
        guard samples.count >= 2, let a = avg else { return nil }
        let v = samples.reduce(0) { $0 + ($1 - a) * ($1 - a) } / Double(samples.count)
        return v.squareRoot()
    }
    public var isReachable: Bool { !samples.isEmpty }
}

/// Result of the speed module (download + upload), measured through the tunnel.
public struct SpeedResult: Hashable, Sendable {
    public let downloadMbps: Double
    public let uploadMbps: Double
    /// Latency observed during the speed test (unloaded), if measured.
    public let latencyMs: Double?

    public init(downloadMbps: Double, uploadMbps: Double, latencyMs: Double? = nil) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.latencyMs = latencyMs
    }
}

/// Combined per-profile result used by the UI / CLI table.
public struct ProfileResult: Identifiable, Sendable {
    public var id: String { profile.id }
    public let profile: OVPNProfile
    public var latency: LatencyResult?
    public var speed: SpeedResult?
    public var error: String?

    public init(profile: OVPNProfile, latency: LatencyResult? = nil, speed: SpeedResult? = nil, error: String? = nil) {
        self.profile = profile
        self.latency = latency
        self.speed = speed
        self.error = error
    }
}
