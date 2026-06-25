# Roadmap / Ideas

## ✅ Done (validated)
- **Profile library** — app imports `.ovpn` files into its own store (`~/Library/Application Support/OVPNSpeedTest/profiles/`). No external folder watching.
- **Latency + jitter module** (no root, parallel) — TCP-handshake RTT to the server (port 443 for UDP profiles, since ICMP is rate-limited/dropped by VPN nodes). Retransmit outliers (~1s TCP RTO) are reclassified as packet loss instead of polluting jitter. ~10 profiles in ~5s.
- **Speed module** — Cloudflare `speed.cloudflare.com` `__down`/`__up`, N parallel streams chunked back-to-back (chunk < 100 MB cap), byte counting in a URLSession delegate, warm-up window excluded. Measured through whatever the default route is (the tunnel once up).
- **OpenVPN runner** — launches `openvpn` via `sudo`, detects "Initialization Sequence Completed", runs work through the tunnel, tears down via the written pidfile.

## 🔜 Planned

### Per-destination quality test (user request)
Let the user enter a **target destination IP** (e.g. an AWS Battlefield game server) and, for
every profile, report the **real ping and packet loss to that destination through the tunnel**.

- Flow: for each profile → connect via OpenVPN → from inside the tunnel, send N ICMP/UDP
  probes to the destination IP → record min/avg/max RTT, jitter, loss → disconnect → next.
- Rank profiles by latency+loss **to that specific destination**, not just to the VPN node.
- This is the metric that actually matters for gaming/low-latency use: the closest VPN node
  isn't necessarily the one with the best path to the game server.
- Complexity: like the speed test, it's sequential (one tunnel at a time, needs root). Best to
  **fold it into the same connection session** as the speed test so we connect once per profile
  and measure {speed, destination-ping, destination-loss} together before disconnecting.
- Destination ping through the tunnel: prefer ICMP (`SOCK_DGRAM`/`IPPROTO_ICMP`, unprivileged on
  macOS) bound to the tunnel's source; fall back to TCP-connect timing if ICMP to the target is
  filtered. Allow an optional custom port for game servers (UDP probe + reply timing is ideal but
  needs a server that answers; TCP-connect to a known open port is the reliable fallback).

### Other ideas
- **Speedtest (Ookla) fallback** — only if Cloudflare ever fails (it currently works fine).
- **Auto re-rank** — combine ping + jitter + loss + (optional) speed into a single score.
- **Scheduled re-tests** — re-measure top profiles periodically and keep a history.
- **Export** — copy the best profile's path / reveal in Finder / export results as CSV.
