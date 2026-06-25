import Foundation
import SwiftUI
import OVPNCore

/// One row in the results table.
struct ProfileRow: Identifiable {
    let profile: OVPNProfile
    var id: String { profile.id }
    var latency: LatencyResult?
    var speed: SpeedResult?
    /// Live status text ("connecting…", "↓ 84 Mbps", "auth failed", …).
    var status: String = ""
    var busy: Bool = false

    var name: String { profile.name }
    var location: String { profile.host ?? "—" }
    var ping: Double? { latency?.median }
    var jitter: Double? { latency?.jitter }
    var loss: Double? { latency == nil ? nil : latency!.lossPct }
    var down: Double? { speed?.downloadMbps }
    var up: Double? { speed?.uploadMbps }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var rows: [ProfileRow] = []
    @Published var selection: Set<String> = []
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var status: String = "Add some .ovpn profiles to begin."
    @Published var isBusy = false
    @Published var privileged = false
    @Published var openvpnInstalled = true

    private let store = ProfileStore()
    private let credStore = CredentialStore()
    private var currentTask: Task<Void, Never>?

    init() {
        let creds = credStore.load()
        username = creds.username
        password = creds.password
        refreshEnvironment()
        reload()
    }

    // MARK: - Environment

    func refreshEnvironment() {
        openvpnInstalled = OpenVPNRunner.locateBinary() != nil
        privileged = PrivilegeSetup.isConfigured()
    }

    // MARK: - Library

    func reload() {
        let profiles = store.load()
        rows = profiles.map { p in
            rows.first(where: { $0.id == p.id }) ?? ProfileRow(profile: p)
        }
        if rows.isEmpty {
            status = "Add some .ovpn profiles to begin."
        } else {
            status = "\(rows.count) profile\(rows.count == 1 ? "" : "s") in library."
        }
    }

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

    func saveCredentials() {
        credStore.save(.init(username: username, password: password))
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
        let targets = selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { status = "Select at least one profile."; return }
        guard openvpnInstalled else { status = "openvpn not installed — run: brew install openvpn"; return }
        guard !username.isEmpty, !password.isEmpty else { status = "Enter your VPN username and password first."; return }
        guard privileged else { status = "Click “Setup” to grant openvpn privileged access first."; return }

        isBusy = true
        saveCredentials()
        let user = username, pass = password
        let profiles = targets.map(\.profile)

        currentTask = Task {
            for (idx, profile) in profiles.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.status = "[\(idx + 1)/\(profiles.count)] \(profile.name): pinging…"
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

    // MARK: - Row mutation helpers

    private func apply(latency: LatencyResult, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].latency = latency
    }
    private func apply(speed: SpeedResult, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].speed = speed
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

    /// Rows as shown in the table (already kept sorted by ping after a ping run).
    var sortedDisplayRows: [ProfileRow] { rows }

    /// The lowest-latency profile that has a measurement.
    var bestRow: ProfileRow? {
        rows.filter { $0.ping != nil }.min { $0.ping! < $1.ping! }
    }
}
