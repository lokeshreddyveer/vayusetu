# Engineering architecture revision — 2026-10-12

User target: an explicitly authorized local DNS-only tunnel, with no remote VPN profile/server and no standalone native DNS settings configuration. This is recorded as a revised experimental architecture target. It is not silently redefined as the existing native DoH/DoT mode.

Platform gate: Apple TN3120 identifies system-wide DNS interception via packet tunnels as unsupported and recommends DNS settings/proxy APIs. TN3134 restricts DNS proxy use on iOS to supervised or per-app managed deployments. Entitlement signing and a successful prototype alone cannot establish supported consumer distribution. The existing native encrypted DNS path remains available as a distinct supported implementation while the proposed runtime is unavailable.

Implemented foundation: ProtectionRuntime/RuntimeCapabilities are shared platform-independent contracts. Current WireGuard supports remote VPN and selected encrypted resolver configuration, with no local filtering. IKEv2 supports remote VPN with server-managed DNS; it cannot satisfy selected encrypted resolver or local filtering requests. Native DNS supports selected DoH/DoT with system selection. Local DNS tunnel and OpenVPN are unavailable. A policy request for unavailable capabilities returns an explicit rejection instead of another runtime. The DNS advanced screen reads the same matrix as VPN mode validation.

This is a capability contract, not the full Swift actor coordinator, local packet codec, DNS forwarding/cache engine, secure revisioned IPC, local filtering runtime, VPN Only profile-DNS implementation or complete release validation requested in the specification. Existing ProtectionSnapshot semantics and working network runtimes are retained. No cosmetic repository relocation or empty package scaffolding was performed.

Changed files: Packages/VayuSetuCore/Sources/VayuSetuCore/Protection.swift; ios/Sources/Store.swift; ios/Sources/DNSViews.swift; ios/Tests/RuntimeTests.swift.

References:
https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers
https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment

Validation: 24 lifecycle/evidence/capability checks passed, including eight new runtime capability checks. Final signed iOS build succeeded and installed on the physical iPhone. No local DNS-tunnel feasibility test, traffic/filtering verification, network handoff or macOS runtime validation was run in this phase.
