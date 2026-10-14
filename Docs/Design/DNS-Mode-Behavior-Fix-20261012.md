# DNS mode behavior correction — 2026-10-12

## Root causes

- VPN-managed DNS looked selectable but its conflict branch always disabled Apply. It could not start a selected VPN.
- Local filtering was presented as a radio mode despite lacking an enforceable adapter.
- The view task reinitialized the draft mode every time the screen returned from resolver selection. The iPhone test reproduced Encrypted DNS resetting to System DNS and a disabled Apply button.
- System DNS could show an enabled Apply because a previous independent DNS request/configuration existed, even when the observed mode was already System DNS.
- Saving encrypted DNS through NEDNSSettingsManager does not enable it. iOS requires user activation in Settings. Saved preferences must not be presented as active protection.
- A post-start cached disconnected status produced stale failure text even after the VPN connected. The final screenshot exposed this race; startup now waits briefly for NEVPN status notifications and the displayed result follows live status.
- Connecting/disconnecting/reasserting VPN states must not be labeled as a settled active DNS mode.

## Implemented behavior

Three transport choices: System DNS, Encrypted DNS, VPN-Managed DNS. Local filtering is a separate unavailable compatibility capability, not a selectable transport.

Current mode, selected mode, and configuration status are separate. Unknown/foreign configurations are not inferred to be System DNS. Returning from the resolver library preserves the draft. The preferred resolver is shown and validated, with a direct route to resolver management. An unchanged mode cannot Apply. Pending saved-DNS cleanup is an explicit separate action. Saving an unchanged pending encrypted resolver again is disabled because it cannot activate iOS DNS.

AppStore serializes DNS/VPN transitions, validates the destination before stopping existing protection, reloads OS ownership, and refuses foreign DNS conflicts. Confirmation explicitly describes stopping VPN protection or connecting the selected VPN. Disconnect must finish within a bounded wait before independent DNS changes proceed. Superseded operations cannot later start a VPN. DNS removal failures block VPN startup. Existing connection adapters are reused; no bypass or new traffic route is introduced.

SystemDNSController reports operation success/failure and distinguishes saved-but-disabled configuration from OS-enabled configuration. No response test, accepted configuration, or connected VPN is promoted into verified transport/filtering/leak protection.

## Changed source and tests

- ios/Sources/DNSViews.swift — mode controls, state presentation, resolver navigation, selection persistence, filtering compatibility.
- ios/Sources/Store.swift — serialized transitions and selected-profile preflight.
- ios/Sources/PrivacyFeatures.swift — owned configuration observation and explicit DNS operation results.
- ios/Sources/Secrets.swift — pure observed-mode/change policy. Persisted RoutingMode values remain unchanged.
- ios/Tests/RouteTests.swift — 14 mode-policy checks, in addition to the earlier resolver-identity checks.
- ios/UITests/LaunchTests.swift — confirmation/cancellation, resolver-return persistence, real DNS save/removal, and live VPN connect/disconnect.

## Validation

Signed iPhone build-for-testing succeeded. Installed app remains version 0.11.2 (18); no TestFlight upload.

Final code regression: 372 checks passed across core, routing, WireGuard policy, lifecycle/evidence, features, verification, IP probes, manual protocols, QR/IKEv2 and profile management. Routing suite: 103 checks. These are configuration/policy tests, not packet-path proof.

Real iPhone 18 Pro Max on Wi-Fi:

- testDNSModeConfigurationRoundTrip: passed, 19.335 seconds. Saved the preferred encrypted DNS with the OS API; observed activation-required status and System DNS remaining current; verified no repeat Apply; confirmed removal of owned DNS settings.
- testDNSModeSelectionStepThree: passed, 14.786 seconds. Validated unchanged System DNS, actionable VPN confirmation/cancellation, and encrypted resolver selection.
- testDNSModeVPNConnectionRoundTrip: passed, 15.860 seconds. Apply initiated a real selected-profile connection; observed VPN-Managed DNS only after connection; confirmed System DNS stopped the VPN; connected status did not retain stale failure text.

Evidence:

- ios/build/dns-mode-complete-validation-20261012.xcresult (3 tests, zero failures; 49.982 seconds total)
- docs/verification-dns-mode-final/ — final save/activation-required, mode, and connected VPN screenshots
- Earlier navigation-fixed and VPN-roundtrip results remain historical; the final combined run validates the installed build.

Earlier failed runs were used to reproduce the mode-reset bug and refine pending-configuration cleanup. They are not counted as passing results. Tests ended with VPN disconnected and owned independent DNS configuration removed; saved resolver/profile metadata and credentials were preserved.

## Limits

Encrypted DNS activation in Settings has not been independently exercised in this pass, nor have cellular, each VPN profile/protocol, packet-path, filtering or tunnel-failure leak tests. The VPN round trip used the currently selected saved profile. Local filtering remains unavailable; OpenVPN remains on hold. No complete protection guarantee is claimed.

Apple requires user activation: https://developer.apple.com/documentation/networkextension/nednssettingsmanager/isenabled
