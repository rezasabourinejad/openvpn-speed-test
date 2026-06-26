import Foundation

/// Launches the `openvpn` binary against a profile, waits for the tunnel to come up,
/// runs an async operation through it, then tears the tunnel down cleanly.
///
/// openvpn needs root (it creates a utun device and rewrites the default route), so we
/// launch it through `sudo`. The app installs a passwordless sudoers rule once via
/// `PrivilegeSetup` so individual tests don't prompt.
public final class OpenVPNRunner {
    public enum RunError: Error, CustomStringConvertible {
        case binaryNotFound
        case authFailed
        case timeout
        case needsPrivilege(String)
        case launchFailed(String)
        case profileUnreadable

        public var description: String {
            switch self {
            case .binaryNotFound: return "openvpn binary not found (install with: brew install openvpn)"
            case .authFailed: return "authentication failed — check username/password"
            case .timeout: return "tunnel did not come up in time"
            case .needsPrivilege(let s): return "privilege error: \(s)"
            case .launchFailed(let s): return "failed to launch openvpn: \(s)"
            case .profileUnreadable: return "could not read the .ovpn file"
            }
        }
    }

    public var connectTimeout: TimeInterval
    public var openvpnPath: String?       // override; otherwise auto-detected

    public init(connectTimeout: TimeInterval = 25, openvpnPath: String? = nil) {
        self.connectTimeout = connectTimeout
        self.openvpnPath = openvpnPath
    }

    /// Common Homebrew / system locations for the openvpn binary.
    public static func locateBinary() -> String? {
        let candidates = [
            "/usr/local/sbin/openvpn",   // Intel Homebrew
            "/usr/local/bin/openvpn",
            "/opt/homebrew/sbin/openvpn",// Apple Silicon Homebrew
            "/opt/homebrew/bin/openvpn",
            "/usr/sbin/openvpn",
            "/usr/bin/openvpn",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // fall back to `which`
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["openvpn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    /// Connect, run `body` through the tunnel, then disconnect. Always tears down.
    /// `onLog` streams openvpn stdout/stderr lines for the UI.
    public func withTunnel<T>(
        profile: OVPNProfile,
        username: String,
        password: String,
        onLog: (@Sendable (String) -> Void)? = nil,
        body: () async throws -> T
    ) async throws -> T {
        guard let binary = openvpnPath ?? Self.locateBinary() else { throw RunError.binaryNotFound }

        // Build an isolated working dir with a patched config + credentials file.
        let work = try makeWorkDir(profile: profile, username: username, password: password)
        defer { try? FileManager.default.removeItem(at: work.dir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            "-n",                                  // never prompt; rely on sudoers rule
            binary,
            "--config", work.config.path,
            "--auth-user-pass", work.creds.path,
            "--auth-nocache",
            "--connect-retry-max", "1",
            "--connect-timeout", "10",
            "--writepid", work.pidFile.path,
            // NOTE: do NOT pass --log; it redirects openvpn's output to a file, and we need
            // it on stdout/stderr so we can detect "Initialization Sequence Completed".
            "--verb", "3",
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let upSignal = ConnectSignal()
        let lineHandler: @Sendable (String) -> Void = { line in
            onLog?(line)
            if line.contains("Initialization Sequence Completed") {
                upSignal.markUp()
            } else if line.contains("AUTH_FAILED") {
                upSignal.markAuthFailed()
            } else if line.contains("sudo: a password is required") || line.contains("sudo: a terminal is required") {
                upSignal.markPrivilege()
            }
        }
        attachLineReader(outPipe.fileHandleForReading, handler: lineHandler)
        attachLineReader(errPipe.fileHandleForReading, handler: lineHandler)

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }

        // Wait for "up", auth failure, privilege error, process exit, or timeout.
        let deadline = Date().addingTimeInterval(connectTimeout)
        while true {
            if upSignal.isUp { break }
            if upSignal.authFailed { teardown(process, pidFile: work.pidFile); throw RunError.authFailed }
            if upSignal.privilege {
                teardown(process, pidFile: work.pidFile)
                throw RunError.needsPrivilege("passwordless sudo not configured — run the one-time setup")
            }
            if !process.isRunning {
                throw RunError.launchFailed("openvpn exited before connecting (see log)")
            }
            if Date() > deadline { teardown(process, pidFile: work.pidFile); throw RunError.timeout }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // Tunnel is up — give routing a brief moment to settle, then run the work.
        try? await Task.sleep(nanoseconds: 600_000_000)
        defer { teardown(process, pidFile: work.pidFile) }
        return try await body()
    }

    // MARK: - Teardown

    private func teardown(_ process: Process, pidFile: URL) {
        // openvpn runs as root, so signal it via sudo using the pid it wrote.
        if let pidStr = try? String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !pidStr.isEmpty {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = ["-n", "/bin/kill", "-TERM", pidStr]
            try? kill.run()
            kill.waitUntilExit()
        }
        if process.isRunning { process.terminate() }
        // Reap.
        process.waitUntilExit()
    }

    // MARK: - Work dir

    private struct Work {
        let dir: URL
        let config: URL
        let creds: URL
        let pidFile: URL
    }

    private func makeWorkDir(profile: OVPNProfile, username: String, password: String) throws -> Work {
        guard var text = try? String(contentsOf: profile.fileURL, encoding: .utf8) else {
            throw RunError.profileUnreadable
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ovpn-speedtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let credsURL = dir.appendingPathComponent("creds.txt")
        let configURL = dir.appendingPathComponent("config.ovpn")
        let pidURL = dir.appendingPathComponent("ovpn.pid")

        // Remove the bare `auth-user-pass` directive; we pass the creds file via CLI flag.
        text = text
            .split(whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != "auth-user-pass" }
            .joined(separator: "\n")

        try (username + "\n" + password + "\n").write(to: credsURL, atomically: true, encoding: .utf8)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        // Creds file must not be world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsURL.path)

        return Work(dir: dir, config: configURL, creds: credsURL, pidFile: pidURL)
    }

    // MARK: - Line reading

    private func attachLineReader(_ handle: FileHandle, handler: @escaping @Sendable (String) -> Void) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            buffer.feed(data) { line in handler(line) }
        }
    }
}

/// Thread-safe latch for connection state transitions.
final class ConnectSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _up = false, _auth = false, _priv = false
    var isUp: Bool { lock.lock(); defer { lock.unlock() }; return _up }
    var authFailed: Bool { lock.lock(); defer { lock.unlock() }; return _auth }
    var privilege: Bool { lock.lock(); defer { lock.unlock() }; return _priv }
    func markUp() { lock.lock(); _up = true; lock.unlock() }
    func markAuthFailed() { lock.lock(); _auth = true; lock.unlock() }
    func markPrivilege() { lock.lock(); _priv = true; lock.unlock() }
}

/// Splits a byte stream into lines for incremental log parsing.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func feed(_ chunk: Data, _ emit: (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) { emit(line) }
        }
    }
}
