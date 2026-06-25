import Foundation

/// The app's own profile library. Profiles are *imported* (copied) into the app's
/// Application Support directory — the user never has to keep .ovpn files around or
/// point the app at an external folder. Everything the app tests lives here.
public final class ProfileStore {
    public let root: URL
    public let profilesDir: URL

    public init(appName: String = "OVPNSpeedTest") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = base.appendingPathComponent(appName, isDirectory: true)
        self.profilesDir = root.appendingPathComponent("profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
    }

    /// All profiles currently in the library, parsed and sorted by name.
    public func load() -> [OVPNProfile] {
        ProfileParser.parseDirectory(profilesDir)
    }

    /// Import a .ovpn file by copying it into the library. Returns the parsed profile.
    /// If a file with the same name exists, it is replaced (re-importing updates it).
    @discardableResult
    public func add(from source: URL) throws -> OVPNProfile {
        let name = source.lastPathComponent
        let dest = profilesDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        guard let profile = ProfileParser.parse(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw StoreError.invalidProfile(name)
        }
        return profile
    }

    /// Import many at once; returns the successfully imported profiles.
    public func addAll(from sources: [URL]) -> (added: [OVPNProfile], failed: [String]) {
        var added: [OVPNProfile] = []
        var failed: [String] = []
        for url in sources where url.pathExtension.lowercased() == "ovpn" {
            do { added.append(try add(from: url)) }
            catch { failed.append(url.lastPathComponent) }
        }
        return (added, failed)
    }

    /// Remove a profile from the library.
    public func remove(_ profile: OVPNProfile) {
        try? FileManager.default.removeItem(at: profile.fileURL)
    }

    public func removeAll() {
        for p in load() { remove(p) }
    }

    public enum StoreError: Error, CustomStringConvertible {
        case invalidProfile(String)
        public var description: String {
            switch self {
            case .invalidProfile(let n): return "“\(n)” is not a valid .ovpn profile"
            }
        }
    }
}

/// Persists the service username/password (and last settings) outside source code.
/// Stored in the app's Application Support dir with 0600 perms — not in the bundle,
/// not in git.
public final class CredentialStore {
    private let fileURL: URL

    public init(appName: String = "OVPNSpeedTest") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("credentials.json")
    }

    public struct Credentials: Codable, Sendable {
        public var username: String
        public var password: String
        public init(username: String = "", password: String = "") {
            self.username = username
            self.password = password
        }
    }

    public func load() -> Credentials {
        guard let data = try? Data(contentsOf: fileURL),
              let c = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return Credentials()
        }
        return c
    }

    public func save(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
