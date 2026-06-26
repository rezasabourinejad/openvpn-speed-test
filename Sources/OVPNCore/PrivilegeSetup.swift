import Foundation

/// openvpn needs root. Rather than prompt for a password on every single test, the app
/// installs a one-time passwordless sudoers rule (via a single admin prompt) that lets the
/// current user run *only* the openvpn binary and `kill` without a password.
public enum PrivilegeSetup {
    public static let sudoersPath = "/etc/sudoers.d/ovpn-speedtest"

    /// True if passwordless sudo for openvpn already works (no prompt needed).
    ///
    /// We can't use `sudo -n -l <binary>`: it exits 0 whenever the user *may* run the
    /// command at all (e.g. via a blanket `(ALL) ALL` rule), even if a password would be
    /// required. Instead we actually invoke `sudo -n <binary> --version` and check whether
    /// sudo refused for lack of a password. (`openvpn --version` exits 1 by design — we look
    /// at stderr, not the exit code.)
    public static func isConfigured() -> Bool {
        guard let binary = OpenVPNRunner.locateBinary() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", binary, "--version"]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return false }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return !errStr.contains("password is required") && !errStr.contains("terminal is required")
    }

    public enum SetupError: Error, CustomStringConvertible {
        case binaryNotFound
        case cancelledOrFailed
        public var description: String {
            switch self {
            case .binaryNotFound: return "openvpn not found — install it with: brew install openvpn"
            case .cancelledOrFailed: return "privileged setup was cancelled or failed"
            }
        }
    }

    /// Install the sudoers rule. Shows one macOS admin password prompt.
    /// Safe: writes to a temp file, validates with `visudo -c`, then moves it into place.
    public static func install() throws {
        guard let binary = OpenVPNRunner.locateBinary() else { throw SetupError.binaryNotFound }
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: \(binary), /bin/kill\n"

        // Build a shell script that validates before installing.
        let script = """
        set -e
        TMP=$(mktemp)
        printf '%s' \(shellQuote(rule)) > "$TMP"
        chmod 0440 "$TMP"
        /usr/sbin/visudo -cf "$TMP"
        /usr/bin/install -m 0440 -o root -g wheel "$TMP" \(shellQuote(sudoersPath))
        rm -f "$TMP"
        """

        let osa = "do shell script \(appleScriptQuote(script)) with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw SetupError.cancelledOrFailed }
    }

    /// Remove the sudoers rule (one admin prompt).
    public static func uninstall() throws {
        let script = "rm -f \(shellQuote(sudoersPath))"
        let osa = "do shell script \(appleScriptQuote(script)) with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw SetupError.cancelledOrFailed }
    }

    // MARK: - Quoting helpers

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
