# Split tunneling on the Mac: what is possible

**Decision: not built. VayuSetu's WireGuard tunnel cannot do per-app split tunneling.** This note records why, and what could be done instead.

## What per-app split tunneling needs

"Send Safari through the VPN, keep Mail outside it" means routing by *which app* opened a connection. macOS offers two ways:

1. **A transparent proxy or app-proxy provider** (`NETransparentProxyProvider`, `NEAppProxyProvider`). The extension sees each flow with the app that opened it and decides where to send it. This is how the large VPN apps do it. For example, the Surfshark and Proton VPN system extensions on a Mac include a *TransparentProxy* beside their WireGuard tunnel.
2. **Per-app VPN** (`NEVPNProtocol.appRules`), which Apple limits to managed (MDM-deployed) devices.

## Why VayuSetu's tunnel cannot

VayuSetu's VPN is a **packet tunnel** (`NEPacketTunnelProvider`). It sees IP packets, not apps. The only routing control a packet tunnel has is by **destination address**: the routes it includes and the routes it excludes. A packet carries no information about which program sent it.

## What is available today, with no new code

A profile's `AllowedIPs` line decides which destinations go through the tunnel. Setting it to a list of ranges (instead of `0.0.0.0/0`) sends only those through the VPN, and everything else outside it. That is split tunneling **by destination**, and it already works with any imported profile. Using it is a decision for the profile's owner.

## What it would take to do it by app

A second system extension, a transparent proxy provider, that forwards chosen apps' flows into the WireGuard tunnel (for example through a local socket) and lets the rest bypass it. It is a new extension with its own signing, provisioning profile and approval step, a new failure surface next to the tunnel and the filter, and it would need the same connection test the tunnel has. It is a large project, not a feature, and it should only start if users ask for it.

## The network filter is not a substitute

The network filter (a content filter) can *block* by app. It cannot *reroute* a flow, so it cannot choose which interface an app uses.
