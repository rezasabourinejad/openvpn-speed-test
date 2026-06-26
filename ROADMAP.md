# Roadmap / Ideas

## ✅ Done (validated)
- **Profile library** — app imports `.ovpn` files into its own store (`~/Library/Application Support/OVPNSpeedTest/profiles/`). No external folder watching.
- **Latency + jitter module** (no root, parallel) — TCP-handshake RTT to the server (port 443 for UDP profiles, since ICMP is rate-limited/dropped by VPN nodes). Retransmit outliers (~1s TCP RTO) are reclassified as packet loss instead of polluting jitter. ~10 profiles in ~5s.
- **Speed module** — Cloudflare `speed.cloudflare.com` `__down`/`__up`, N parallel streams chunked back-to-back (chunk < 100 MB cap), byte counting in a URLSession delegate, warm-up window excluded. Measured through whatever the default route is (the tunnel once up).
- **OpenVPN runner** — launches `openvpn` via `sudo`, detects "Initialization Sequence Completed", runs work through the tunnel, tears down via the written pidfile.
- **Per-destination quality test** — user enters a target IP/host (e.g. a game server) + optional
  port. For each selected profile: connect → from inside the tunnel probe the destination → record
  min/avg/max RTT, jitter, round-trip loss → disconnect → next; results sorted by ping to the
  target. Probe is native ICMP echo via unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` (validated: macOS
  prepends the IPv4 header on receive, which we strip; replies matched by sequence since the kernel
  may rewrite the id). Falls back to TCP-connect timing on the given port if ICMP is filtered.
  `DestinationPinger` in OVPNCore; CLI: `ovpn-test dest <file> -u U -p P --ip <ip> [--port N]`.
  Round-trip loss only — separating in/out loss needs a cooperating server, which a game server isn't.

## 🔜 Planned

### Other ideas
- **Speedtest (Ookla) fallback** — only if Cloudflare ever fails (it currently works fine).
- **Auto re-rank** — combine ping + jitter + loss + (optional) speed into a single score.
- **Scheduled re-tests** — re-measure top profiles periodically and keep a history.
- **Export** — copy the best profile's path / reveal in Finder / export results as CSV.
