# VayuSetu for iOS — 1.0 (build 22)

Sections below headed with older version numbers are history, not the current feature list.

Working project: ~/Documents/VayuSetu/ios. Native iPhone app, iOS 17+. The macos/ sibling contains the native Mac app and system extension.

## Implemented

- Official WireGuard backend embedded in a packet-tunnel extension.
- Provider-independent WireGuard import, manual creation/editing, duplication, rename, selection and deletion.
- Default redacted configuration sharing removes private/preshared keys and comments. Exports retain addresses, public keys and server endpoints and cannot establish a connection.
- Multiple named DNS-over-HTTPS profiles with custom HTTPS host/path endpoints. Control D is one supported endpoint format, not a hardcoded provider.
- Credentials and resolver URLs stored in device-local Keychain; extension preferences contain persistent references rather than raw secrets.
- Versioned atomic VPN/DNS metadata; legacy VPN arrays remain readable. Invalid storage blocks changes to preserve files.
- VPN → DNS configuration with full routes; optional includeAllNetworks and on-demand settings.
- Explicit IPv6 capture/drop policy when the profile has no usable native IPv6 interface and default route.
- OS tunnel status, handshake/counters, sampled traffic rates, network availability, timestamped resolver probes, external-IP probes and sanitized event sharing.
- Separate free-signing preview and full VPN schemes.

## DNS routing and limits

VPN → DNS configures system DoH and ordinary website connections through the WireGuard tunnel. This is an intended configuration; actual packet paths, filtering and leak behavior remain unverified on a provisioned device.

DNS → VPN is unavailable pending proof of DNS-only bypass on iOS. Resolver-IP exceptions permit arbitrary traffic to bypass and do not meet the supplied blueprint. The updated controller, extension and route compiler reject that mode. Loading the updated full app disables its saved direct-mode on-demand rules and requests that tunnel stop. Remove old VPN configuration from iOS Settings if an older app/extension remains installed.

Endpoint authentication headers, query-string authentication, custom ports, DoT, DoQ, automatic fallback, split DNS and custom resolver bootstrap addresses are not implemented. HTTPS endpoints are validated, standard TLS is used, redirects are rejected, probe responses are bounded to the DNS message maximum and probe deadlines are set.

Resolver-host and VPN-endpoint bootstrap uses the current system network before tunnel startup. Resolver addresses remain pinned for the connection; reconnect after address changes. Apps using their own DNS may bypass system DNS filtering. Apple networking settings have system exceptions: no absolute kill-switch or zero-leak guarantee is claimed.

Profiles must include an IPv4 interface address and IPv4 default route. IPv6-only, NAT64/DNS64 and transition behavior require additional work and evidence. A tunnel-established indication does not mean verified protection.

## Launch on your iPhone

Open ~/Documents/VayuSetu/ios/VayuSetu.xcodeproj in Xcode.

1. For interface/configuration testing, choose the **VayuSetu** scheme, select your Personal Team, choose your connected iPhone and Run.
2. For actual VPN testing, choose **VayuSetuVPN**. Select a team with Network Extension provisioning for both **VayuSetuVPN** and **VayuSetuTunnel**, including the shared Keychain group. Choose your iPhone and Run.
3. In the full app, import or create a WireGuard profile, create/select a named DoH resolver, save it and connect. iOS requests permission to create a VPN configuration.
4. Check handshake/counters and independent external-IP, resolver and packet-path evidence before relying on the configuration.

The schemes have separate containers. Preview profiles are not automatically transferred to the VPN app. The paid team X4MH29QNRS now provisions both VPN targets. Signed builds are in dist/signed and dist/release; the full VPN app was installed and its Home screen visually verified on the paired iPhone. Unsigned build products cannot be installed directly. iOS uses signed app/IPA distribution, not a DMG.

Disconnect disables saved on-demand rules until the next connection. Remove Saved VPN deletes the system configuration and active credential snapshot. Remove every profile/resolver before uninstalling if you want their Keychain items deleted; Keychain data can survive uninstall. Original imported files remain in Files.

## Build and checks

Xcode is required. The pinned Go toolchain lives in Tools/ and is not installed globally. If missing, run python3 scripts/setup.py. Run bash scripts/build.sh for all checks and four unsigned build products, or bash scripts/test.sh for the 79 host checks. dist/BUILD-PRODUCTS.txt records final bundle verification.

Host checks exercise parser failures, DoH URL validation, DNS replies, redacted exports, native route configuration, capability rejection before route mutation, and official WireGuard IPv6 policy. They are not on-device UI, Keychain, network-path or leak tests.

## Outstanding release work

No real provider credentials were supplied. No live handshake, resolver-path/filter verification, leak testing, sleep/wake or Wi-Fi/cellular recovery test has been performed. No iOS simulator runtime is installed. On-device Home launch is verified; full automated interaction and real tunnel recovery/rollback testing remain outstanding. Header-authenticated DNS and independently verified network protection are not complete. Bounded foreground retry and preference rollback are implemented, but require live failure testing.

A paid-team signed IPA is included in dist/release/VayuSetuVPN.ipa, and its exported app and extension signatures were checked. No TestFlight upload or public release was performed. Mac release tooling and outputs are in ../macos/. See BUILD-STATUS.md and ../Docs for evidence gates and the target architecture.

## Privacy

No analytics, telemetry or browsing/query-history logging. Network requests happen only when you ask for them: DNS probes go to your selected resolver; public-IP checks contact api.ipify.org and api6.ipify.org, with 4.ident.me and 6.ident.me as fallback; the optional ASN lookup sends the measured public IP to stat.ripe.net (RIPE); filter-list updates download from the list URLs you enabled (defaults: raw.githubusercontent.com and small.oisd.nl). Shared diagnostic events omit keys, resolver endpoints, profiles, server endpoints and observed public IPs. Redacted configuration exports have a different scope and include nonsecret network configuration. Dependency notices and privacy manifests are bundled.

## Version 0.4.2 additions

One shared design: deep black glass, blue accents and a circular power control, with native tabs and secondary Logs/History navigation. Existing icon assets are retained; no new images were generated.

Packages/VayuSetuCore is linked by both iOS app schemes and owns configuration metadata, connection stages, retry/evidence policies and session history contracts. Platform services remain in ios/. Three XCTest package tests pass in addition to 79 CLI host checks.

The app implements foreground bounded reconnect (three attempts, exponential delay), a 30-second startup watchdog, operation cancellation, previous-configuration rollback, network-path evidence invalidation, periodic counter sampling, session duration, bounded local session history, sanitized OSLog events, LAN preference and explicit connection-check evidence. Recovery and rollback still require real extension failure injection. Foreground retry does not replace iOS-managed on-demand background recovery.

Connection checks contact the selected resolver and the IPv4/IPv6 public-IP test destinations listed under Privacy. A probe success is scoped to that observation; DNS transport, IPv6 enforcement and routing isolation remain unverified until independently tested. The app does not show a verified secure state from OS connection status alone.

A self-hosted Apple Silicon/Xcode validation workflow is prepared in ../.github/workflows/ios.yml for owner-controlled pushes/manual runs. It has not run on GitHub. It requires a configured runner and the vendored source to be present in the repository. No repository was pushed or automation service configured.

For a provisioned signed IPA, set VAYU_DEVELOPMENT_TEAM and run bash scripts/release/archive-ios.sh. The script validates signatures, packet-tunnel entitlements, provisioning and shared Keychain for both app and extension before local export. It does not upload. Paid-team app/extension signing and the exported IPA were verified. See ../Docs/Paid-Team-Signing.md.

## UI refinement — 0.4.2

Hidden scroll indicators in all content screens and the configuration editor; inline page titles; tighter card padding, borders and spacing; shorter tab labels; labeled resolver fields; equal Save/Test actions; compact probe summaries with expandable evidence; profile status tags and native action menus; aligned settings rows; compact traffic grids; consistent Logs/History navigation; restrained success banners; refined editing/rename sheets; and native confirmations for resolver/history deletion. Existing networking and stored profiles are preserved. The signed preview is installed on the connected iPhone. Device visual review remains separate from build/installation checks.

## Startup crash correction — 0.4.2

The 0.4.1 UI refactor caused a SwiftUI generic-metadata stack overflow during first layout. Screen and card helpers now use stable AnyView boundaries to limit metadata depth. On the connected iPhone, 0.4.2 launches, stays alive and renders Home (confirmed by screenshot). A launch-service acknowledgement alone is no longer treated as launch verification.

UITests/LaunchTests.swift and the VayuSetuUI scheme exercise three cold launches, every tab and the manual profile editor. Run bash scripts/test-ui.sh <device-UDID> with the iPhone unlocked. The initial on-device automation run is waiting for the phone to unlock; it is not recorded as passed.

## Research-based UI redesign — 0.4.3

Based on official Proton VPN redesign and Apple Liquid Glass guidance (sources in Docs/UI-Design-Research.md). Native navigation floats above near-black content surfaces. Home emphasizes connection state and a concentric power control, with compact VPN/DNS configuration rows. Resolver selection precedes editing; forms, badges, profiles and settings use consistent spacing and restrained surfaces. Scroll indicators stay hidden.

Validation: 79 host checks passed; preview and VPN unsigned device/simulator builds passed; signed preview installed on the connected iPhone. All five main screens were opened independently and inspected via device screenshots. Automated interaction regression remains blocked by the device's UI-testing authorization; sheet/button interactions are not claimed verified. Existing AnyView metadata boundaries were preserved. DEBUG-only --ui-tab 0...4 supports direct screen visual checks without modifying saved data.

## Free-signing renewal

Use `bash scripts/renew-ios.sh renew` to rebuild, sign and reinstall the preview on your paired iPhone. An opt-in launchd scheduler is included and remains disabled. See Docs/Renewal.md for enable/disable, expiration checks and limitations.

## DNS dashboard — 0.6.0

The DNS tab now contains a selected-resolver summary, compact query-type menu, one test action and a routing summary. Resolver selection, editing, test evidence and routing explanations open separate native sheets. Endpoint editing uses a local draft; Cancel leaves the selected resolver unchanged, and persistence failure restores the previous selection. Resolver changes remain disabled while connected. Existing AnyView presentation boundaries are preserved.

The signed build and release archive compile; 79 checks pass. The IPA and its extension signatures/profiles were verified. Installation succeeds, but on-device visual review is currently blocked by Apple's online profile validation: device logs show Profile Needs Network Validation followed by No network route / Network is down. This is a pre-launch OS rejection, not a new app crash.


Feature expansion: encrypted backups/restores, DoT, custom DNS test domains, HTTPS quality history, live traffic charts, per-profile usage, data alerts, persistent sanitized logs, configurable retry/timeouts and optional native IPv6. Current limitations and verification status: [capability matrix](../Docs/Architecture/Implementation-Gaps.md).
