import Foundation
import SwiftUI
import OVPNCore

/// One row in the results table.
struct ProfileRow: Identifiable {
    let profile: OVPNProfile
    var id: String { profile.id }
    var latency: LatencyResult?
    var speed: SpeedResult?
    /// Per-destination ping/loss to the user's target IP, measured through the tunnel.
    var destination: LatencyResult?
    /// How the destination was probed ("ICMP" or "TCP").
    var destMethod: String?
    /// Live status text ("connecting…", "↓ 84 Mbps", "auth failed", …).
    var status: String = ""
    var busy: Bool = false
    /// True if this profile has its own credential override.
    var hasOverride: Bool = false

    var name: String { profile.name }
    var provider: String { profile.providerKey }
    var location: String { profile.host ?? "—" }
    var ping: Double? { latency?.median }
    var jitter: Double? { latency?.jitter }
    var loss: Double? { latency == nil ? nil : latency!.lossPct }
    var down: Double? { speed?.downloadMbps }
    var up: Double? { speed?.uploadMbps }
    var destPing: Double? { destination?.median }
    var destLoss: Double? { destination == nil ? nil : destination!.lossPct }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var rows: [ProfileRow] = []
    @Published var selection: Set<String> = []
    @Published var status: String = "Add some .ovpn profiles to begin."
    @Published var isBusy = false
    @Published var privileged = false
    @Published var openvpnInstalled = true

    // Per-provider credentials shown in the toolbar.
    @Published var selectedProvider: String = ""
    @Published var groupUsername: String = ""
    @Published var groupPassword: String = ""

    // Per-destination test target (e.g. a game server IP) + optional TCP fallback port.
    @Published var destinationHost: String = ""
    @Published var destinationPort: String = ""

    private let store = ProfileStore()
    private let credStore = CredentialStore()
    private var currentTask: Task<Void, Never>?

    init() {
        refreshEnvironment()
        reload()
    }

    /// Distinct providers across the library (for the credentials picker).
    var providers: [String] { Array(Set(rows.map { $0.provider })).sorted() }

    // MARK: - Environment

    func refreshEnvironment() {
        openvpnInstalled = OpenVPNRunner.locateBinary() != nil
        privileged = PrivilegeSetup.isConfigured()
    }

    // MARK: - Library

    func reload() {
        let profiles = store.load()
        rows = profiles.map { p in
            var row = rows.first(where: { $0.id == p.id }) ?? ProfileRow(profile: p)
            row.hasOverride = credStore.hasOverride(p.id)
            return row
        }
        if rows.isEmpty {
            status = "Add some .ovpn profiles to begin."
        } else {
            status = "\(rows.count) profile\(rows.count == 1 ? "" : "s") in library."
        }
        // Keep the credentials picker pointed at a valid provider.
        if selectedProvider.isEmpty || !providers.contains(selectedProvider) {
            selectProvider(providers.first ?? "")
        }
    }

    // MARK: - Credentials

    /// Point the toolbar fields at a provider and load its saved credentials.
    func selectProvider(_ provider: String) {
        selectedProvider = provider
        let c = credStore.groupCredentials(provider)
        groupUsername = c.username
        groupPassword = c.password
    }

    /// Save the toolbar fields as the selected provider's credentials.
    func saveGroupCredentials() {
        guard !selectedProvider.isEmpty else { return }
        credStore.setGroup(selectedProvider, .init(username: groupUsername, password: groupPassword))
    }

    /// Override credentials for specific profiles (nil clears the override).
    func setOverride(ids: Set<String>, username: String, password: String) {
        let creds: CredentialStore.Credentials? =
            (username.isEmpty && password.isEmpty) ? nil : .init(username: username, password: password)
        for id in ids { credStore.setOverride(id, creds) }
        for i in rows.indices where ids.contains(rows[i].id) {
            rows[i].hasOverride = credStore.hasOverride(rows[i].id)
        }
        let n = ids.count
        status = creds == nil ? "Cleared override for \(n) profile\(n == 1 ? "" : "s")."
                              : "Set custom credentials for \(n) profile\(n == 1 ? "" : "s")."
    }

    /// Existing override for a single profile (for pre-filling the editor).
    func override(for id: String) -> CredentialStore.Credentials? { credStore.override(id) }

    func importProfiles(_ urls: [URL]) {
        let (added, failed) = store.addAll(from: urls)
        reload()
        if !added.isEmpty {
            status = "Imported \(added.count) profile\(added.count == 1 ? "" : "s")."
        }
        if !failed.isEmpty {
            status += "  Skipped: \(failed.joined(separator: ", "))"
        }
    }

    func remove(ids: Set<String>) {
        for id in ids {
            if let row = rows.first(where: { $0.id == id }) { store.remove(row.profile) }
        }
        selection.subtract(ids)
        reload()
    }

    // MARK: - Privilege

    func setupPrivilege() {
        Task.detached {
            do {
                try PrivilegeSetup.install()
                await MainActor.run { self.refreshEnvironment(); self.status = "Privileged access configured ✓" }
            } catch {
                await MainActor.run { self.status = "Setup failed: \(error)" }
            }
        }
    }

    // MARK: - Tests

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        isBusy = false
        for i in rows.indices { rows[i].busy = false }
        status = "Stopped."
    }

    /// Ping + jitter for every profile (fast, parallel, no root).
    func testPingAll() {
        guard !isBusy else { return }
        isBusy = true
        status = "Pinging \(rows.count) profiles…"
        let profiles = rows.map(\.profile)
        let tester = LatencyTester()

        currentTask = Task {
            let t0 = Date()
            _ = await tester.measureAll(profiles) { profile, result in
                Task { @MainActor in self.apply(latency: result, to: profile.id) }
            }
            await MainActor.run {
                self.sortByPing()
                self.isBusy = false
                self.status = String(format: "Ping done in %.1fs — sorted by latency.", Date().timeIntervalSince(t0))
            }
        }
    }

    /// Speed test (download + upload) through the tunnel for the selected profiles
    /// (or all, if none selected). Each profile: ping → connect → measure → disconnect.
    func testSpeedSelected() {
        guard !isBusy else { return }
        guard let resolved = resolveTunnelJobs() else { return }

        isBusy = true
        currentTask = Task {
            for (idx, job) in resolved.enumerated() {
                let (profile, creds) = job
                let user = creds.username, pass = creds.password
                if Task.isCancelled { break }
                await MainActor.run {
                    self.status = "[\(idx + 1)/\(resolved.count)] \(profile.name): pinging…"
                    self.setBusy(true, id: profile.id)
                    self.setStatus("pinging…", id: profile.id)
                }
                // 1) ping first (so the row always has latency before speed)
                let lat = await LatencyTester().measure(host: profile.host ?? "", port: profile.latencyPort)
                await MainActor.run { self.apply(latency: lat, to: profile.id) }

                // 2) connect + speed test through the tunnel
                await MainActor.run { self.setStatus("connecting…", id: profile.id) }
                let runner = OpenVPNRunner()
                do {
                    let speed = try await runner.withTunnel(profile: profile, username: user, password: pass) {
                        let tester = SpeedTester()
                        tester.onProgress = { mbps, phase in
                            Task { @MainActor in
                                let tag = phase == .download ? "↓" : "↑"
                                self.setStatus(String(format: "%@ %.0f Mbps", tag, mbps), id: profile.id)
                            }
                        }
                        return await tester.run()
                    }
                    await MainActor.run {
                        self.apply(speed: speed, to: profile.id)
                        self.setStatus("", id: profile.id)
                        self.setBusy(false, id: profile.id)
                    }
                } catch {
                    await MainActor.run {
                        self.setStatus("⚠︎ \(error)", id: profile.id)
                        self.setBusy(false, id: profile.id)
                    }
                }
            }
            await MainActor.run {
                self.isBusy = false
                self.status = "Speed test complete."
            }
        }
    }

    /// Per-destination quality test: connect through each selected profile and measure
    /// real ping + packet loss to `destinationHost` (ICMP, TCP fallback to the port).
    func testDestinationSelected() {
        guard !isBusy else { return }
        let target = destinationHost.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { status = "Enter a destination IP or host first."; return }
        guard let resolved = resolveTunnelJobs() else { return }
        let port = UInt16(destinationPort.trimmingCharacters(in: .whitespaces))

        isBusy = true
        currentTask = Task {
            for (idx, job) in resolved.enumerated() {
                let (profile, creds) = job
                if Task.isCancelled { break }
                await MainActor.run {
                    self.status = "[\(idx + 1)/\(resolved.count)] \(profile.name): connecting…"
                    self.setBusy(true, id: profile.id)
                    self.setStatus("connecting…", id: profile.id)
                }
                let runner = OpenVPNRunner()
                do {
                    let dest = try await runner.withTunnel(profile: profile,
                                                           username: creds.username, password: creds.password) {
                        await MainActor.run { self.setStatus("probing \(target)…", id: profile.id) }
                        let pinger = DestinationPinger(tcpFallbackPort: port)
                        return await pinger.measure(host: target)
                    }
                    await MainActor.run {
                        self.apply(destination: dest, to: profile.id)
                        self.setStatus("", id: profile.id)
                        self.setBusy(false, id: profile.id)
                    }
                } catch {
                    await MainActor.run {
                        self.setStatus("⚠︎ \(error)", id: profile.id)
                        self.setBusy(false, id: profile.id)
                    }
                }
            }
            await MainActor.run {
                self.sortByDestPing()
                self.isBusy = false
                self.status = "Destination test complete — sorted by ping to \(target)."
            }
        }
    }

    /// Resolve credentials (override → provider → default) for the selected profiles
    /// (or all, if none selected). Returns nil and sets `status` if anything is missing.
    private func resolveTunnelJobs() -> [(OVPNProfile, CredentialStore.Credentials)]? {
        let targets = selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { status = "Select at least one profile."; return nil }
        guard openvpnInstalled else { status = "openvpn not installed — run: brew install openvpn"; return nil }
        guard privileged else { status = "Click “Setup” to grant openvpn privileged access first."; return nil }

        // Save whatever is currently typed for the selected provider before running.
        saveGroupCredentials()

        let jobs: [(OVPNProfile, CredentialStore.Credentials)?] = targets.map { row in
            guard let c = credStore.resolve(for: row.profile), !c.isEmpty else { return nil }
            return (row.profile, c)
        }
        if jobs.contains(where: { $0 == nil }) {
            let missing = Set(targets.enumerated().filter { jobs[$0.offset] == nil }.map { $0.element.provider })
            status = "No credentials for: \(missing.sorted().joined(separator: ", ")). Set them first."
            return nil
        }
        return jobs.compactMap { $0 }
    }

    // MARK: - Row mutation helpers

    private func apply(latency: LatencyResult, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].latency = latency
    }
    private func apply(speed: SpeedResult, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].speed = speed
    }
    private func apply(destination: DestinationResult, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].destination = destination.result
        rows[i].destMethod = destination.method.rawValue
    }
    private func setStatus(_ s: String, id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].status = s
    }
    private func setBusy(_ b: Bool, id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].busy = b
    }

    func sortByPing() {
        rows.sort { ($0.ping ?? .greatestFiniteMagnitude) < ($1.ping ?? .greatestFiniteMagnitude) }
    }

    func sortByDestPing() {
        rows.sort { ($0.destPing ?? .greatestFiniteMagnitude) < ($1.destPing ?? .greatestFiniteMagnitude) }
    }

    /// Rows as shown in the table (already kept sorted by ping after a ping run).
    var sortedDisplayRows: [ProfileRow] { rows }

    /// The lowest-latency profile that has a measurement.
    var bestRow: ProfileRow? {
        rows.filter { $0.ping != nil }.min { $0.ping! < $1.ping! }
    }
}
