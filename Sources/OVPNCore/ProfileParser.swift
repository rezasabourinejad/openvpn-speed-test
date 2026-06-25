import Foundation

public enum ProfileParser {
    /// Parse a single .ovpn file. Returns nil if it has no usable remote.
    public static func parse(_ url: URL) -> OVPNProfile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text: text, fileURL: url)
    }

    static func parse(text: String, fileURL: URL) -> OVPNProfile? {
        var remotes: [OVPNProfile.Remote] = []
        var proto = "udp"
        var cn: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }

            switch key {
            case "remote":
                // remote <host> [port] [proto]
                guard parts.count >= 2 else { continue }
                let host = parts[1]
                let port = parts.count >= 3 ? UInt16(parts[2]) ?? 1194 : 1194
                remotes.append(.init(host: host, port: port))
                if parts.count >= 4 { proto = parts[3].lowercased() }
            case "proto":
                if parts.count >= 2 {
                    // normalize udp4/tcp-client etc. to udp/tcp
                    proto = parts[1].lowercased().hasPrefix("tcp") ? "tcp" : "udp"
                }
            case "verify-x509-name":
                if parts.count >= 2 {
                    let v = parts[1]
                    if v.uppercased().hasPrefix("CN=") {
                        cn = String(v.dropFirst(3))
                    } else {
                        cn = v
                    }
                }
            default:
                break
            }
        }

        guard !remotes.isEmpty else { return nil }
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let name = cn ?? fileName
        return OVPNProfile(fileURL: fileURL, name: name, remotes: remotes, proto: proto)
    }

    /// Parse every .ovpn in a directory (non-recursive), sorted by name.
    public static func parseDirectory(_ dir: URL) -> [OVPNProfile] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.pathExtension.lowercased() == "ovpn" }
            .compactMap(parse)
            .sorted { $0.name < $1.name }
    }
}
