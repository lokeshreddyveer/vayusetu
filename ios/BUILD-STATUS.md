# iOS build status — 0.4.2, 2026-10-10

## Passed

- 69 host CLI checks: 40 parser/DNS/export, 14 native route configuration, 6 official WireGuard policy and 9 lifecycle/evidence contracts.
- 3 shared Swift package XCTest tests, zero failures.
- Four unsigned Debug builds: preview/full VPN for device and simulator.
- Final bundle version 0.4.2, iOS 17+, iPhone family, device arm64, simulator arm64/x86_64.
- Embedded extension principal/identifier, native WireGuard symbols, privacy and license resources.
- Release script shell syntax and signing-verifier Python compilation.

## Implemented in this iteration

Shared Swift package integration; common black/blue glass design and circular connection control; connection stages; startup deadline; bounded foreground retries; cancellation and setup rollback; network-path evidence invalidation; explicit IPv4/IPv6/DoH checks with honest verdicts; periodic traffic samples; local bounded session history; sanitized OSLog events; dedicated Logs/History screens; LAN policy preference; prepared validation workflow and signed IPA export tools.

## Not passed / not complete

No live VPN handshake, DNS transport/filter proof, IPv6 blocking/leak evidence, sleep/wake/path-change recovery or extension crash/failure test. No paid Network Extension provisioning confirmed. No signed full-VPN IPA/TestFlight release. Advanced DNS → VPN remains unavailable pending DNS-only bypass feasibility. Header-authenticated resolver transport, NAT64/DNS64 verification and all proposed modular package extraction are incomplete. CI configuration is prepared, not remotely executed. iOS simulator runtime is absent; simulator UI execution is not verified.

The preview signed successfully with the existing Xcode team and installed on the connected iPhone. Launch was attempted and refused by iOS because the phone was locked; UI execution is not verified. Open VayuSetu after unlocking.

A fresh full-VPN signed device build was attempted. Xcode rejected both dev.r3dby.vayusetu.vpn and dev.r3dby.vayusetu.vpn.tunnel because the configured Personal Team does not support Network Extensions. Logs: build/VayuSetu-phone.log and build/VayuSetuVPN-phone.log. This is a confirmed provisioning blocker, not an unsigned-build failure. The preview installation does not validate the VPN extension.

Earlier Go dependency source scan was not rerun: dependencies are unchanged and that scan is not a complete product audit.

## UI refinement validation

The signed 0.4.2 preview built successfully and installed on the connected iPhone. Scroll indicators are hidden and primary layouts/secondary actions are refined. Final unsigned builds are recorded in dist/BUILD-PRODUCTS.txt. UI screenshot comparison/accessibility inspection is not represented as completed.

## Startup crash evidence

A real iPhone crash report for 0.4.1 showed EXC_BAD_ACCESS/SIGSEGV in Swift generic-metadata demangling at first SwiftUI layout. Bounded screen/card view types fixed the observed startup failure. The signed 0.4.2 preview installed, launched and remained alive as PID 1055; a device screenshot confirmed rendered Home. The automated UI regression builds successfully but awaits an unlocked phone at Xcode destination preflight. No UI test pass is claimed until its result bundle confirms it.
