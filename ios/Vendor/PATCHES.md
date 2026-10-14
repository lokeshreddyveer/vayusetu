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
