import SwiftUI
import OVPNCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showImporter = false
    @State private var dropTargeted = false

    // Per-profile credential editor sheet.
    @State private var showCredEditor = false
    @State private var editorIDs: Set<String> = []
    @State private var editorUser = ""
    @State private var editorPass = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            resultsTable
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "ovpn") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.importProfiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .sheet(isPresented: $showCredEditor) { credentialEditor }
    }

    // MARK: - Per-profile credential editor

    private func openCredentialEditor(for ids: Set<String>) {
        editorIDs = ids
        // Pre-fill from the existing override if exactly one profile is selected.
        if ids.count == 1, let id = ids.first, let c = model.override(for: id) {
            editorUser = c.username; editorPass = c.password
        } else {
            editorUser = ""; editorPass = ""
        }
        showCredEditor = true
    }

    private var credentialEditor: some View {
        let names = model.rows.filter { editorIDs.contains($0.id) }.map(\.name)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Custom credentials").font(.headline)
            Text(names.count == 1 ? names[0] : "\(names.count) profiles")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Overrides the provider credentials for \(names.count == 1 ? "this profile" : "these profiles").")
                .font(.caption2).foregroundStyle(.tertiary)
            TextField("username", text: $editorUser).textFieldStyle(.roundedBorder)
            SecureField("password", text: $editorPass).textFieldStyle(.roundedBorder)
            HStack {
                Button("Clear override", role: .destructive) {
                    model.setOverride(ids: editorIDs, username: "", password: "")
                    showCredEditor = false
                }
                Spacer()
                Button("Cancel") { showCredEditor = false }
                Button("Save") {
                    model.setOverride(ids: editorIDs, username: editorUser, password: editorPass)
                    showCredEditor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editorUser.isEmpty && editorPass.isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenVPN Speed Test").font(.headline)
                Text("Find the fastest, lowest-latency profile").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            environmentBadges
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var environmentBadges: some View {
        HStack(spacing: 8) {
            Badge(ok: model.openvpnInstalled,
                  text: model.openvpnInstalled ? "openvpn ready" : "openvpn missing",
                  help: model.openvpnInstalled ? "openvpn binary found" : "Install with: brew install openvpn")
            Badge(ok: model.privileged,
                  text: model.privileged ? "privileged" : "needs setup",
                  help: "Passwordless access for openvpn (needed for speed tests)")
            if !model.privileged {
                Button("Setup") { model.setupPrivilege() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { showImporter = true } label: {
                Label("Add Profiles", systemImage: "plus")
            }

            Divider().frame(height: 18)

            Button { model.testPingAll() } label: {
                Label("Test Ping", systemImage: "wave.3.right")
            }
            .disabled(model.rows.isEmpty || model.isBusy)
            .help("Measure real latency + jitter for all profiles (fast, parallel)")

            Button { model.testSpeedSelected() } label: {
                Label("Test Speed", systemImage: "speedometer")
            }
            .disabled(model.rows.isEmpty || model.isBusy)
            .help("Connect through each selected profile and measure real download/upload")

            if model.isBusy {
                Button(role: .destructive) { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                ProgressView().controlSize(.small).padding(.leading, 2)
            }

            Spacer()

            credentialFields
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var providerBinding: Binding<String> {
        Binding(get: { model.selectedProvider }, set: { model.selectProvider($0) })
    }

    private var credentialFields: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill").foregroundStyle(.secondary).font(.caption)
            if model.providers.count > 1 {
                Picker("", selection: providerBinding) {
                    ForEach(model.providers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                .help("Credentials apply to all profiles from this provider")
            } else if !model.selectedProvider.isEmpty {
                Text(model.selectedProvider).font(.caption).foregroundStyle(.secondary).frame(minWidth: 80)
            }
            TextField("username", text: $model.groupUsername)
                .textFieldStyle(.roundedBorder).frame(width: 140)
                .onChange(of: model.groupUsername) { _ in model.saveGroupCredentials() }
            SecureField("password", text: $model.groupPassword)
                .textFieldStyle(.roundedBorder).frame(width: 120)
                .onChange(of: model.groupPassword) { _ in model.saveGroupCredentials() }
        }
    }

    // MARK: - Table

    private var resultsTable: some View {
        ZStack {
            Table(model.sortedDisplayRows, selection: $model.selection) {
                TableColumn("Profile") { row in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).fontWeight(.medium)
                            Text(row.location).font(.caption2).foregroundStyle(.secondary)
                        }
                        if row.hasOverride {
                            Image(systemName: "key.fill").font(.caption2).foregroundStyle(.tint)
                                .help("Uses custom credentials")
                        }
                    }
                }.width(min: 160, ideal: 200)

                TableColumn("Ping") { row in PingCell(row: row) }.width(90)
                TableColumn("Jitter") { row in Metric(row.jitter, "ms") }.width(70)
                TableColumn("Loss") { row in LossCell(loss: row.loss) }.width(60)
                TableColumn("↓ Download") { row in SpeedCell(value: row.down, status: row.status, phase: "↓") }.width(110)
                TableColumn("↑ Upload") { row in SpeedCell(value: row.up, status: row.status, phase: "↑") }.width(110)
                TableColumn("Status") { row in StatusCell(row: row) }.width(min: 120, ideal: 180)
            }
            .tableStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Set credentials…") { openCredentialEditor(for: ids) }
                if ids.contains(where: { id in model.rows.first(where: { $0.id == id })?.hasOverride == true }) {
                    Button("Clear custom credentials") { model.setOverride(ids: ids, username: "", password: "") }
                }
                Divider()
                Button("Reveal in Finder") { revealInFinder(ids) }
                Button("Remove", role: .destructive) { model.remove(ids: ids) }
            }

            if model.rows.isEmpty { emptyState }
            if dropTargeted { dropOverlay }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No profiles yet").font(.title3).foregroundStyle(.secondary)
            Text("Drag .ovpn files here, or click “Add Profiles”.").font(.callout).foregroundStyle(.tertiary)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(.tint)
            .padding(8)
            .background(Color.accentColor.opacity(0.06))
            .overlay(Text("Drop .ovpn files to import").font(.headline).foregroundStyle(.tint))
            .allowsHitTesting(false)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.status).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if let best = model.bestRow, let ping = best.ping {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                    Text("Best: \(best.name) · \(Int(ping)) ms").font(.caption).fontWeight(.medium)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    // MARK: - Drop / Finder

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { model.importProfiles(urls) } }
    }

    private func revealInFinder(_ ids: Set<String>) {
        let urls = model.rows.filter { ids.contains($0.id) }.map { $0.profile.fileURL }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}
