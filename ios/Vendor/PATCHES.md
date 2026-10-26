# WireGuard integration changes

Base: official WireGuard/wireguard-apple commit 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1.
The original MIT license is preserved and embedded in both app schemes.

- Include sys/types.h explicitly for the current Apple compiler's C module import.
- Replace the adapter's network-settings condition wait with a semaphore and fail
  the start operation on timeout rather than proceeding with uncertain routes.
- Check and propagate backend Device.Up errors as startup failure.
- Pin the current official wireguard-go module and updated x/sys, x/net and x/crypto
  modules in go.mod/go.sum. Module checksum verification remains enabled.
- Build Go locally via scripts/wireguard-go.sh, preserving upstream's continuous
  clock fix against the downloaded current Go source. Go stays inside Tools/ and
  is not installed system-wide. Its download checksum is recorded in Tools/go-version.json.

The app adds its own packet tunnel provider; upstream's app UI is not reused.
WireGuardConfigPolicy handles profile preflight and IPv6 blackhole policy.
RoutePolicy applies the configured native DoH/DoT resolver with IPv4 and IPv6 default capture routes and no resolver-IP route exceptions. VPN → DNS is supported; DNS → VPN is rejected until a DNS-only direct transport can be independently demonstrated. Capturing IPv6 without backend IPv6 routes requests dropping it; this is configuration intent, not independent proof of leak protection.

## dnscache.go (answer cache)
`upstream.exchange` consults a small in-memory cache first (2048 entries, TTL clamped to 120 s, NOERROR/NXDOMAIN only, keyed by
flags + question + EDNS bytes, ID rewritten on hit). Covers both the local DNS-only tunnel and the WireGuard-fronting filter.
Also: replies that exceed the tunnel MTU are answered with a truncated (TC) reply carrying only the question, instead of SERVFAIL.

## dnsdomains.go (optional domain history)
Per-domain allowed/blocked counts, kept only while the app has switched the history on (one atomic load on the lookup path otherwise).
Counts only, no times: at most 4000 distinct names are held, further names count under an empty "other" name, and `wgDNSDomainsTake`
returns the 600 most active and empties the tally, so the tunnel never holds more than a few seconds of it. Switching it off discards it.
The local DNS-only tunnel does the same in Swift (DNSOnlyRuntime).

## dnsrebinding.go (DNS rebinding protection)
A public name answered with an address inside the home network (10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, ::1, fc00::/7, fe80::/10, v4-mapped
private) is answered as NXDOMAIN, counted in `Rebinding`. Exempt: single labels and .local/.lan/.home/.home.arpa/.internal/.localdomain/.localhost/
.intranet/.corp/.plex.direct/.ts.net and reverse zones; 0.0.0.0 and :: (a resolver's own block) and 100.64/10 are not rebinding. An explicit allow rule
for the asked name wins, as for CNAME uncloaking. Enabled by `rebinding` in the DNS config (the app sends it; absent means off in Go, on in the Swift runtime
via the secret). The Swift DNS-only runtime has the same rules (DNSRebinding in DNSOnlyRuntime.swift).

## dnsstats.go (resolver health)
`upstream.exchange` now counts, per upstream, answered lookups (timed into eight buckets: 25/50/100/200/400/800/1600 ms and above), timeouts, other errors and
cache hits. Only lookups that went to the resolver are timed; cache hits and locally blocked names never are. No per-query record is kept. Each upstream
carries a generation that rises with every tunnel start. Exposed as `Upstream` in `wgDNSStats` and through `wgDNSUpstreamStats(handle)` for the DNS-only tunnel.

