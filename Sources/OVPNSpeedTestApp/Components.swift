import SwiftUI

/// Small status pill used in the header (openvpn / privileged).
struct Badge: View {
    let ok: Bool
    let text: String
    var help: String = ""

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(ok ? Color.green : Color.orange)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((ok ? Color.green : Color.orange).opacity(0.12), in: Capsule())
        .help(help)
    }
}

/// A plain numeric metric, e.g. jitter "3.5 ms".
struct Metric: View {
    let value: Double?
    let unit: String
    init(_ value: Double?, _ unit: String) { self.value = value; self.unit = unit }

    var body: some View {
        if let value {
            Text("\(value, specifier: "%.1f") \(unit)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Ping value with a color that reflects quality.
struct PingCell: View {
    let row: ProfileRow

    private var color: Color {
        guard let p = row.ping else { return .secondary }
        switch p {
        case ..<80: return .green
        case ..<150: return .yellow
        case ..<250: return .orange
        default: return .red
        }
    }

    var body: some View {
        if let p = row.ping {
            Text("\(Int(p.rounded())) ms")
                .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                .foregroundStyle(color)
        } else if row.busy {
            Text("…").foregroundStyle(.tertiary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct LossCell: View {
    let loss: Double?
    var body: some View {
        if let loss {
            Text("\(Int(loss.rounded()))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(loss <= 0 ? Color.secondary : (loss < 10 ? Color.orange : Color.red))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Download/upload value, or the live phase reading while testing.
struct SpeedCell: View {
    let value: Double?
    let status: String
    let phase: String   // "↓" or "↑"

    var body: some View {
        if let value {
            Text("\(value, specifier: "%.1f")")
                .font(.system(.body, design: .monospaced)).fontWeight(.medium)
                .foregroundColor(.primary)
            + Text(" Mbps").font(.caption2).foregroundColor(.secondary)
        } else if status.hasPrefix(phase) {
            Text(status).font(.system(.body, design: .monospaced)).foregroundStyle(.tint)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct StatusCell: View {
    let row: ProfileRow
    var body: some View {
        HStack(spacing: 5) {
            if row.busy { ProgressView().controlSize(.mini) }
            Text(displayText)
                .font(.caption)
                .foregroundStyle(row.status.hasPrefix("⚠") ? Color.red : .secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }
    private var displayText: String {
        if !row.status.isEmpty { return row.status }
        if row.speed != nil { return "done" }
        if row.latency != nil { return "ready" }
        return ""
    }
}
