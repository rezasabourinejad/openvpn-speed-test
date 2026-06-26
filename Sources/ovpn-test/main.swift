import Foundation
import OVPNCore

// Minimal CLI used to validate the OVPNCore engine end-to-end.
//
//   ovpn-test ping <file-or-dir> ...      latency + jitter (no root, parallel)
//   ovpn-test speed                       Cloudflare speed test on current route
//   ovpn-test connect <file> -u U -p P    bring a profile up, speed-test through it

func collectProfiles(_ paths: [String]) -> [OVPNProfile] {
    var profiles: [OVPNProfile] = []
    let fm = FileManager.default
    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            profiles.append(contentsOf: ProfileParser.parseDirectory(url))
        } else if let p = ProfileParser.parse(url) {
            profiles.append(p)
        }
    }
    return profiles
}

func fmt(_ d: Double?, _ suffix: String = "") -> String {
    guard let d else { return "  -  " }
    return String(format: "%6.1f%@", d, suffix)
}

func arg(_ flags: [String]) -> String? {
    let a = CommandLine.arguments
    for f in flags {
        if let i = a.firstIndex(of: f), i + 1 < a.count { return a[i + 1] }
    }
    return nil
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    usage:
      ovpn-test ping <file-or-dir>...
      ovpn-test speed
      ovpn-test connect <file> -u <user> -p <pass>
      ovpn-test dest <file> -u <user> -p <pass> --ip <ip> [--port <port>]
    """)
    exit(1)
}

switch cmd {
case "ping":
    let paths = args.dropFirst().filter { !$0.hasPrefix("-") }
    let profiles = collectProfiles(Array(paths))
    guard !profiles.isEmpty else { print("no profiles found"); exit(1) }
    print("Pinging \(profiles.count) profile(s) — TCP handshake RTT...\n")
    let tester = LatencyTester(samplesPerHost: 8, perProbeTimeout: 2.0, maxConcurrentHosts: 40)
    let t0 = Date()
    let results = await tester.measureAll(profiles)
    let dt = Date().timeIntervalSince(t0)

    print(String(format: "%-26@ %7@ %7@ %7@ %7@ %6@", "PROFILE" as CVarArg, "ping" as CVarArg, "jitter" as CVarArg, "min" as CVarArg, "max" as CVarArg, "loss%" as CVarArg))
    print(String(repeating: "─", count: 70))
    func medianOf(_ p: OVPNProfile) -> Double { results[p.id]?.median ?? 1e9 }
    for p in profiles.sorted(by: { medianOf($0) < medianOf($1) }) {
        guard let r = results[p.id] else { continue }
        let name = String(p.name.prefix(26))
        print(String(format: "%-26@ %@ %@ %@ %@ %5.0f%%",
                     name as CVarArg,
                     fmt(r.median, "ms") as CVarArg,
                     fmt(r.jitter, "ms") as CVarArg,
                     fmt(r.min) as CVarArg,
                     fmt(r.max) as CVarArg,
                     r.lossPct))
    }
    print(String(format: "\nDone in %.1fs", dt))

case "speed":
    print("Cloudflare speed test on current route (no VPN switch)...")
    let tester = SpeedTester()
    tester.debugErrors = true
    tester.onProgress = { mbps, phase in
        let tag = phase == .download ? "↓" : "↑"
        FileHandle.standardError.write("\r\(tag) \(String(format: "%.1f", mbps)) Mbps   ".data(using: .utf8)!)
    }
    print("\nDownload:")
    let down = await tester.measureDownload()
    print(String(format: "\r  ↓ Download: %.1f Mbps        ", down))
    print("Upload:")
    let up = await tester.measureUpload()
    print(String(format: "\r  ↑ Upload:   %.1f Mbps        ", up))

case "connect":
    guard let file = args.dropFirst().first(where: { !$0.hasPrefix("-") }),
          let profile = ProfileParser.parse(URL(fileURLWithPath: file)) else {
        print("usage: ovpn-test connect <file> -u <user> -p <pass>"); exit(1)
    }
    let user = arg(["-u", "--user"]) ?? ""
    let pass = arg(["-p", "--pass"]) ?? ""
    guard !user.isEmpty, !pass.isEmpty else { print("need -u and -p"); exit(1) }

    let runner = OpenVPNRunner()
    do {
        let result = try await runner.withTunnel(
            profile: profile, username: user, password: pass,
            onLog: { line in FileHandle.standardError.write(("  [ovpn] " + line + "\n").data(using: .utf8)!) }
        ) {
            print("\n✅ Tunnel up — running speed test through it...")
            let tester = SpeedTester()
            return await tester.run()
        }
        print(String(format: "\n↓ %.1f Mbps   ↑ %.1f Mbps", result.downloadMbps, result.uploadMbps))
    } catch {
        print("❌ \(error)")
        exit(1)
    }

case "dest":
    guard let file = args.dropFirst().first(where: { !$0.hasPrefix("-") }),
          let profile = ProfileParser.parse(URL(fileURLWithPath: file)) else {
        print("usage: ovpn-test dest <file> -u <user> -p <pass> --ip <ip> [--port <port>]"); exit(1)
    }
    let user = arg(["-u", "--user"]) ?? ""
    let pass = arg(["-p", "--pass"]) ?? ""
    let ip = arg(["--ip", "--dest"]) ?? ""
    let port = arg(["--port"]).flatMap { UInt16($0) }
    guard !user.isEmpty, !pass.isEmpty, !ip.isEmpty else { print("need -u, -p and --ip"); exit(1) }

    let runner = OpenVPNRunner()
    do {
        let dest = try await runner.withTunnel(
            profile: profile, username: user, password: pass,
            onLog: { line in FileHandle.standardError.write(("  [ovpn] " + line + "\n").data(using: .utf8)!) }
        ) { () -> DestinationResult in
            print("\n✅ Tunnel up — probing \(ip) through it...")
            let pinger = DestinationPinger(tcpFallbackPort: port)
            return await pinger.measure(host: ip)
        }
        let r = dest.result
        print(String(format: "\n%@ via %@:  ping %@  jitter %@  loss %.0f%%  (min %@ / max %@)",
                     ip, dest.method.rawValue,
                     fmt(r.median, "ms"), fmt(r.jitter, "ms"), r.lossPct,
                     fmt(r.min), fmt(r.max)))
    } catch {
        print("❌ \(error)")
        exit(1)
    }

case "check":
    print("openvpn binary : \(OpenVPNRunner.locateBinary() ?? "NOT FOUND (brew install openvpn)")")
    print("privileged     : \(PrivilegeSetup.isConfigured())")

case "setup":
    do {
        try PrivilegeSetup.install()
        print("install ok — privileged now: \(PrivilegeSetup.isConfigured())")
    } catch {
        print("❌ \(error)"); exit(1)
    }

default:
    print("unknown command: \(cmd)")
    exit(1)
}
