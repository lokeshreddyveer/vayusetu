# VayuSetu protection hardening — iOS 0.10.0 (14)

This build improves enforcement and recovery. It is not a certification, a military-grade guarantee, or independent proof of leak protection.

## Implemented fixes

- Startup/stop sequencing: a generation gate prevents a resolver lookup that finishes after a stop from starting a stale tunnel. Startup completion is delivered once. Late accepted-settings callbacks cannot restore evidence for a stopped generation.
- Resolver bootstrap: a five-second startup deadline, at most two outstanding system lookups, bounded address count, and rejection of unspecified, loopback, multicast, link-local and ambiguous addresses. Private addresses remain available for explicitly configured internal resolvers. Timed-out system lookup workers can continue in the OS, but cannot enqueue a stale adapter start; worker capacity stays bounded.
- Optional provider bootstrap IPs: editable per resolver, preserved in Keychain-referenced tunnel configuration and encrypted backups. Existing profiles/backups remain readable. Pins avoid the resolver hostname's pre-tunnel system lookup; they do not change the hostname's certificate validation or add excluded routes. Use only provider-published addresses. There is no automatic substitute resolver. VPN endpoint hostname bootstrap is still handled by upstream WireGuard and may use system DNS.
- Strict routing: requests capture of local-network, APNs and internet-routable cellular-service traffic and enables any-interface on-demand recovery. The saved protocol and on-demand rules are checked after iOS preferences reload. The extension also rejects a missing strict protocol when the secret requires strict routing. Custom preferences remain stored when strict mode is disabled.
- Production strict builds disable the device-communication exception. Debug builds retain it to allow Xcode/USB/Wi-Fi debugging; their isolation is intentionally weaker. Calls, notifications and local-device access may be affected by strict routing. Required OS/carrier exceptions may remain.
- Non-nil unprepared/inactive extension settings are rejected; deliberate nil withdrawal remains supported for upstream shutdown/path recovery.
- Debug diagnostic runner refuses a VPN-required measurement unless connection stability was established; old reports are not fresh evidence.

## Threat coverage and limits

| Threat | App contribution | Remaining requirement |
| --- | --- | --- |
| Unsafe Wi-Fi / ISP observation | WireGuard encryption, encrypted configured DNS, strict routing and on-demand requests | Independent traffic-path and failure-isolation measurements; unavoidable OS exceptions |
| Malicious sites / trackers | Configured resolver's DNS filtering, existing controlled-domain checks | Provider filtering policy must be configured; DNS cannot inspect allowed encrypted content or prevent all phishing/first-party tracking |
| Targeted attacker | Smaller startup/recovery attack surface, bounded inputs and secret-safe diagnostics | Device/OS integrity, current updates, account security, independent review; a VPN cannot repair a compromised endpoint |

Apple's [Lockdown Mode](https://support.apple.com/en-us/105120) is an optional platform protection for sophisticated targeted attacks and restricts some device features. It is not enabled by this app. Apple's [VPN routing documentation](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic) describes system traffic exceptions; includeAllNetworks is a request to the OS, not proof of complete isolation.

## Assessment of the supplied architecture note

Use the process separation, versioned schemas, immutable configuration compilation, bounded IPC/logging, pure validation/state transitions and fixture-based tests. A plan fingerprint can identify a configuration mismatch, but cannot authenticate the plan by itself or prove the route. System VPN status and current extension health must be combined, with stale reports invalidated. “Read-only Keychain access” needs actual access-control design, not a comment. Do not adopt resolver-IP exclusions for DNS-first: they bypass all traffic to those IPs. Keep that mode unavailable until a DNS-specific design is enforced and independently measured. A shared package refactor is incremental; this build does not pretend a full TunnelPlan compiler or observer service already exists.

## Validation

- 270 contract checks passed: core 50, routing/lifecycle/bootstrap 77, WireGuard policy 8, runtime 16, feature/backup 34, verification/filtering 30, public-IP diagnostics 55.
- Four shared-package XCTest cases passed, including legacy resolver decoding and bootstrap round-trip.
- Signed iOS Debug and Release builds succeeded; app/extension team, provisioning, entitlements and shared Keychain verified.
- Shared macOS host sources typechecked. Existing macOS app, DMG and TestFlight builds were not replaced by this pass.
- iOS development build installed and launched on the user's real iPhone. Live new-build Wi-Fi/cellular and new UI results are pending below.

## Remaining release gates

1. Independent observer evidence for actual DNS transport, IPv4/IPv6 isolation, tunnel failure, reconnect, and Wi-Fi/cellular roaming. Public-IP discovery and configuration snapshots do not fulfill this gate.
2. New-build hardware results, including calling/notification behavior and production-build device-communication restrictions.
3. Provider-published resolver bootstrap addresses if avoiding pre-tunnel system resolver lookup is required; upstream VPN endpoint lookup remains a separate concern.
4. Independent security review and longer-running extension resource measurements. The previous dependency scan is not a cryptographic audit; no new third-party dependency was added.

Security status remains “Tunnel established · unverified” until independent verification passes.
