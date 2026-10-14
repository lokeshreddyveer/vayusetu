# Unified iOS architecture — platform review

Reviewed the user's Unified iOS Architecture specification against the current runtime and Apple's current documentation on 2026-10-12.

## Adopted design

One protection coordinator, shared provider-neutral DNS/filtering policy, explicit adapter capabilities, controlled transitions, independent Safari blocking, and desired/configured/observed/verified state remain the design direction. No second competing personal VPN should be started.

## Required correction

Do not treat a local DNS-focused NEPacketTunnelProvider as an approved production implementation. Apple TN3120 explicitly classifies system-wide DNS interception through packet tunnels as unsupported and directs developers to DNS settings or DNS proxy APIs. A physical-device prototype does not establish supported deployment or App Store eligibility. TN3134 restricts iOS DNS proxy deployment to supervised devices, or per-app use on managed devices. Consumer iPhone deployment therefore cannot assume a general DNS proxy entitlement is enough.

## Supported implementation matrix

DNS Only: NEDNSSettingsManager with selected DoH/DoT configuration. User selects the saved configuration in iOS Settings. Filtering is upstream provider filtering where actually configured and observed; no local blocklist execution claim.

VPN Only: selected adapter's VPN DNS policy. Current WireGuard runtime always requests the preferred encrypted resolver via RoutePolicy, so a genuine VPN Only mode requires a separate policy-preserving implementation before exposing that mode. IKEv2 currently uses server-managed DNS.

VPN + encrypted DNS: current WireGuard runtime installs selected DoH/DoT settings after adapter startup. This does not implement a local filtering engine. Treat native IKEv2 as server-managed DNS unless independently supported capability is established.

Safari: independent content blocker, with selected/compiled/reload-acknowledged/OS-enabled/effectiveness distinctions. Previously paused Adblock implementation remains paused.

OpenVPN: remains unavailable per user's licensing decision.

## Current code evidence

PacketTunnelProvider.startTunnel loads a WireGuard configuration, validates resolver/bootstrap, and starts WireGuardAdapter. RoutePolicy applies encrypted DNS settings; there is no DNS-only packet decoder/forwarder, cache or local blocklist runtime. Adding a three-mode selector without those runtimes would misrepresent current functionality.

## Next supported work

Preserve DNS-only desired intent separately from temporary VPN suspension; implement explicit VPN policy capabilities and transitions with rollback; consolidate mutation entry points behind the coordinator; invalidate evidence across policy/network transitions. Keep unsupported local DNS interception unavailable. A future local-engine deployment proposal needs specific supported-platform justification or Apple clarification before becoming the default consumer runtime.

## Sources

https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers
https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
https://developer.apple.com/documentation/networkextension/nednssettingsmanager

No app code or installed build was changed during this platform review. No new device tests were run or claimed.
