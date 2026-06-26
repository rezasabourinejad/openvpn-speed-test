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

/// Persists VPN credentials outside source code (Application Support, mode 0600 — not in
/// the bundle, not in git).
///
/// Credentials are organised **per provider** (e.g. all `*.nordvpn.com` profiles share one
/// username/password), with an optional **per-profile override** for special cases, and a
/// **default** fallback. Resolution order for a profile: override → provider group → default.
public final class CredentialStore {
    public struct Credentials: Codable, Sendable, Equatable {
        public var username: String
        public var password: String
        public init(username: String = "", password: String = "") {
            self.username = username
            self.password = password
        }
        public var isEmpty: Bool { username.isEmpty && password.isEmpty }
    }

    private struct Store: Codable {
        var groups: [String: Credentials]
        var overrides: [String: Credentials]
        var def: Credentials?
    }
    /// Old single-credential format, for one-time migration.
    private struct Legacy: Codable { var username: String; var password: String }

    private let fileURL: URL
    private var store: Store

    public init(appName: String = "OVPNSpeedTest") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("credentials.json")
        self.store = Self.read(fileURL)
    }

    private static func read(_ url: URL) -> Store {
        guard let data = try? Data(contentsOf: url) else {
            return Store(groups: [:], overrides: [:], def: nil)
        }
        if let s = try? JSONDecoder().decode(Store.self, from: data) { return s }
        // Migrate the old single-credential file into the default fallback.
        if let l = try? JSONDecoder().decode(Legacy.self, from: data) {
            return Store(groups: [:], overrides: [:],
                         def: Credentials(username: l.username, password: l.password))
        }
        return Store(groups: [:], overrides: [:], def: nil)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Provider groups

    public func groupCredentials(_ provider: String) -> Credentials {
        store.groups[provider] ?? (store.def ?? Credentials())
    }
    public func setGroup(_ provider: String, _ c: Credentials) {
        if c.isEmpty { store.groups[provider] = nil } else { store.groups[provider] = c }
        persist()
    }

    // MARK: - Per-profile overrides

    public func hasOverride(_ profileID: String) -> Bool {
        !(store.overrides[profileID]?.isEmpty ?? true)
    }
    public func override(_ profileID: String) -> Credentials? { store.overrides[profileID] }
    public func setOverride(_ profileID: String, _ c: Credentials?) {
        if let c, !c.isEmpty { store.overrides[profileID] = c } else { store.overrides[profileID] = nil }
        persist()
    }

    // MARK: - Resolution

    /// Effective credentials for a profile: override → provider group → default.
    public func resolve(for profile: OVPNProfile) -> Credentials? {
        if let o = store.overrides[profile.id], !o.isEmpty { return o }
        if let g = store.groups[profile.providerKey], !g.isEmpty { return g }
        if let d = store.def, !d.isEmpty { return d }
        return nil
    }
}
