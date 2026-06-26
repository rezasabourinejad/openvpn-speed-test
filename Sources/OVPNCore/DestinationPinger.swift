import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// How a destination measurement was actually obtained.
public enum ProbeMethod: String, Sendable {
    case icmp = "ICMP"
    case tcp  = "TCP"
}

/// Result of a per-destination quality test through a tunnel.
public struct DestinationResult: Sendable {
    public let host: String
    public let method: ProbeMethod
    public let result: LatencyResult

    public init(host: String, method: ProbeMethod, result: LatencyResult) {
        self.host = host
        self.method = method
        self.result = result
    }
}

/// Measures real round-trip latency + packet loss to an arbitrary destination IP
/// (e.g. a game server) **through whatever the current default route is** — i.e.
/// through the OpenVPN tunnel once `OpenVPNRunner` has brought it up.
///
/// Primary probe is ICMP echo via an unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` socket
/// (no root needed on macOS, same mechanism as Apple's SimplePing). If the destination
/// filters ICMP (zero replies), we fall back to timing TCP handshakes to an optional
/// user-supplied port. This yields true min/avg/max RTT, jitter and **round-trip** loss.
///
/// Note: round-trip loss only — separating inbound vs outbound loss to a third-party
/// server is impossible without the server cooperating, so we don't claim it.
public final class DestinationPinger {
    public var samples: Int
    public var perProbeTimeout: Double      // seconds
    public var interProbeGap: Double        // seconds between probes
    /// If ICMP gets zero replies and this is set, fall back to TCP-connect timing here.
    public var tcpFallbackPort: UInt16?

    public init(samples: Int = 12, perProbeTimeout: Double = 1.5,
                interProbeGap: Double = 0.15, tcpFallbackPort: UInt16? = nil) {
        self.samples = samples
        self.perProbeTimeout = perProbeTimeout
        self.interProbeGap = interProbeGap
        self.tcpFallbackPort = tcpFallbackPort
    }

    /// Measure the destination: ICMP first, TCP fallback if ICMP is filtered.
    public func measure(host: String) async -> DestinationResult {
        // ICMP uses blocking sockets; run it off the cooperative pool.
        let icmp = await withCheckedContinuation { (cont: CheckedContinuation<LatencyResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.icmpEchoBlocking(host: host))
            }
        }
        if icmp.received > 0 {
            return DestinationResult(host: host, method: .icmp, result: icmp)
        }
        // ICMP filtered / unavailable → fall back to TCP if we were given a port.
        if let port = tcpFallbackPort {
            let tester = LatencyTester(samplesPerHost: samples, perProbeTimeout: perProbeTimeout)
            let tcp = await tester.measure(host: host, port: port)
            return DestinationResult(host: host, method: .tcp, result: tcp)
        }
        return DestinationResult(host: host, method: .icmp, result: icmp)
    }

    // MARK: - ICMP

    private func icmpEchoBlocking(host: String) -> LatencyResult {
        guard var dest = Self.resolveIPv4(host) else {
            // Couldn't resolve — surface as "not tested" rather than fake 100% loss.
            return LatencyResult(host: host, port: 0, samples: [], attempts: 0)
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            // ICMP socket unavailable on this system → let caller try TCP.
            return LatencyResult(host: host, port: 0, samples: [], attempts: 0)
        }
        defer { close(fd) }

        let ident = UInt16(truncatingIfNeeded: getpid())
        var rtts: [Double] = []

        for s in 0..<samples {
            let seq = UInt16(truncatingIfNeeded: s + 1)
            let pkt = Self.makeEcho(ident: ident, seq: seq)
            let start = DispatchTime.now()

            let sent: Int = pkt.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) { sap in
                    sap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sapp in
                        sendto(fd, raw.baseAddress, raw.count, 0, sapp,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent >= 0, let rtt = waitForReply(fd: fd, seq: seq, start: start) {
                rtts.append(rtt)
            }
            // else: send error or timeout → counts as loss (attempts - received).

            if interProbeGap > 0 && s + 1 < samples {
                usleep(useconds_t(interProbeGap * 1_000_000))
            }
        }
        return LatencyResult(host: host, port: 0, samples: rtts, attempts: samples)
    }

    /// Block (with `poll`) until a matching echo reply arrives or the timeout elapses.
    private func waitForReply(fd: Int32, seq: UInt16, start: DispatchTime) -> Double? {
        let deadlineNs = start.uptimeNanoseconds &+ UInt64(perProbeTimeout * 1_000_000_000)
        var buf = [UInt8](repeating: 0, count: 1500)

        while true {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= deadlineNs { return nil }
            let remainingMs = Int32(truncatingIfNeeded: (deadlineNs &- nowNs) / 1_000_000)

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, max(1, remainingMs))
            if pr == 0 { return nil }                       // timed out
            if pr < 0 { if errno == EINTR { continue }; return nil }

            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { continue }

            // Match echo reply (type 0) by sequence. With SOCK_DGRAM the kernel may
            // rewrite the identifier, so we key off the sequence number, which is unique
            // per probe within this socket.
            if let (type, rseq) = Self.parseEcho(buf, count: n), type == 0, rseq == seq {
                let ns = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                return Double(ns) / 1_000_000.0
            }
        }
    }

    // MARK: - Packet helpers

    /// Build an 8-byte ICMP echo-request header + 8-byte payload, with checksum filled in.
    static func makeEcho(ident: UInt16, seq: UInt16) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 16)
        pkt[0] = 8                                  // type: echo request
        pkt[1] = 0                                  // code
        // [2,3] checksum — left zero for the computation below
        pkt[4] = UInt8(ident >> 8); pkt[5] = UInt8(ident & 0xff)
        pkt[6] = UInt8(seq >> 8);   pkt[7] = UInt8(seq & 0xff)
        for i in 8..<16 { pkt[i] = UInt8(i) }       // payload pattern
        let csum = checksum(pkt)
        pkt[2] = UInt8(csum >> 8); pkt[3] = UInt8(csum & 0xff)
        return pkt
    }

    /// Standard 16-bit one's-complement Internet checksum.
    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum &+= (UInt32(data[i]) << 8) | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum &+= UInt32(data[i]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xffff) &+ (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    /// Return (icmpType, sequence) from a received datagram, skipping an IPv4 header if
    /// one is present (macOS includes it on `SOCK_DGRAM` ICMP; Linux strips it — handle both).
    static func parseEcho(_ buf: [UInt8], count: Int) -> (UInt8, UInt16)? {
        var off = 0
        if count > 0, (buf[0] >> 4) == 4 {          // IPv4 header present
            off = Int(buf[0] & 0x0f) * 4
        }
        guard count >= off + 8 else { return nil }
        let type = buf[off]
        let seq = (UInt16(buf[off + 6]) << 8) | UInt16(buf[off + 7])
        return (type, seq)
    }

    /// Resolve a host or dotted-quad to an IPv4 `sockaddr_in`.
    static func resolveIPv4(_ host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else { return nil }
        defer { freeaddrinfo(res) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        while let cur = node {
            if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr {
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            node = cur.pointee.ai_next
        }
        return nil
    }
}
