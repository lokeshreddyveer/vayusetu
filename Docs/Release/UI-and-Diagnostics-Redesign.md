# VayuSetu native UI and diagnostics delivery

Project: `~/Documents/VayuSetu`.
Release targets: iOS 0.7.0 (11), macOS 0.4.0 (4).

## Implemented presentation

- Shared adaptive colors, blue accent, consistent rows and actions; hidden scroll indicators.
- iPhone: native five-tab navigation, separate profile/resolver editors, masked credentials, structured health sections.
- macOS: native split navigation, collapsible sidebar with icon rail, profile/DNS master-detail screens, responsive connection dashboard, dedicated logs.
- Profile import, create, edit, duplicate, redacted export and confirmed deletion use existing storage/parser/Keychain services. Editing or duplicating another profile preserves the active selection.
- Resolver selection and editing preserve existing stored endpoints. DNS → VPN remains unavailable with an explanation.
- Settings reuse real persistence, notifications, recovery preferences, encrypted backups, traffic and session history. Mac login and extension actions are in the Mac Integration menu.
- Logs have severity/category/search filters, pause, follow-live, copy and sanitized export.

No configuration files or credentials were migrated, overwritten or removed by the redesign. User-triggered edits still use existing transactional storage services. The earlier root UI source is backed up under each platform’s `build/ui-before-*` folder.

## Connection verification

Public-address discovery, expected-exit comparison and leak evidence are separate concepts and screens. Expected exits are configured per VPN profile; endpoint/server addresses are not assumed to be public exits. Verification samples are discarded on observed connection/configuration/route changes.

Control D identity uses the OS DNS resolver and the provider’s published `verify.controld.com` answers. This is evidence for that sampled DNS path, subject to OS caching. It does not verify the account/profile, DNS transport order, browser overrides or all system DNS. Other providers need independent verification adapters. Unexpected-provider evidence and mismatched/unchanged exits are investigation signals, not a global security verdict.

DNS routing order, routing isolation and device-wide leak protection remain explicitly unverified. No broad resolver route exceptions or VPN bypasses were added.

## DNS-only filtering

Direct A/AAAA requests reuse the existing bounded DoH/DoT transport. A user-selected unfiltered reference must establish that the controlled test name resolves. NXDOMAIN, REFUSED and zero-address sinks are recognized as blocking observations; network errors and unsupported responses remain inconclusive. A pass covers available address families for a particular test name, not category-wide coverage.

Ads/tracker names must be provider-supported or controlled by the user with documented expected policy. The supplied malware name is Cloudflare’s safe `malware.testcategory.com`; other providers need their own documented classification/rule. No malware content, ad scripts or webpages are fetched.

Comparison queries up to ten selected saved endpoints without changing the active resolver. Thirty local comparison runs retain timestamps and per-category results. Export omits endpoints and custom test names. These are DNS-level checks, never browser-based protection scores.

## External-IP investigation and fix

The previous UI diagnostic used `https://api64.ipify.org?format=json` (either family), a 12-second request timeout, a 15-second resource timeout, a 4096-byte response limit, and JSON IP parsing. Every error was replaced by the same generic message, so the earlier exact network failure cannot be recovered from it. The previous health probes used family-specific ipify URLs but also replaced detailed errors with a generic inconclusive verdict.

New probes:

| Family | Primary | Independent fallback |
|---|---|---|
| IPv4 | `https://api.ipify.org?format=json` | `https://4.ident.me/` |
| IPv6 | `https://api6.ipify.org?format=json` | `https://6.ident.me/` |

Each family attempts each operator at most once. Request timeout 8 s, resource timeout 10 s, response limit 4096 bytes. Families run independently. JSON/text responses are validated against the requested address family; IPv6 addresses are normalized. Family-specific DNS hostnames constrain the requested service, although NAT64 may use IPv6 transport to observe an IPv4 exit.

Sanitized evidence records operator, family, timestamp, elapsed time, HTTP status or whitelisted NSError domains/codes. It excludes NSError descriptions/userInfo, headers, resolver URLs/tokens and public addresses in the retained hardware report. DNS, TLS, HTTP, malformed replies, wrong family, timeout, cancellation and connectivity errors are distinct. An IPv6-unavailable label requires failed probes plus NWPath’s report of no IPv6 support; it never means blocking was verified.

Default OS routes and TLS validation apply. No interface binding, custom bootstrap DNS, excluded route, proxy override or trust override was introduced. Equivalent NWPath notifications no longer cancel a measurement; observed route changes still invalidate it. An in-progress/invalidated report replaces earlier evidence to prevent stale-result confusion.

## Verification and remaining work

Automated tests cover existing configuration/routing/WireGuard/recovery/backup contracts plus DNS evidence, IP parsing, fallback bounds, family mismatch, error sanitization and nested route failures. All 167 checks passed. The latest iOS 0.7.0/build 11 Release archive/export and macOS 0.4.0/build 4 universal VPN bundle/signing passed. The corrected iPhone debug build installed and launched successfully.

Real iPhone evidence so far: the signed debug build opens; disconnected Wi-Fi IPv4 and IPv6 both returned addresses through ipify (220 ms / 173 ms). A subsequent launch-time run while the tunnel was established was invalidated by a path change and is not counted as a completed VPN test. Wi-Fi-over-VPN and cellular-over-VPN results require fresh completed samples. Do not interpret the earlier disconnected report as tunneled evidence.

Both IP operators responded for both families on the Mac’s current route; that is endpoint availability evidence, not a macOS VPN test. macOS extension activation/live routing and Apple notarization remain separate deployment steps.

## Changed sources

App entry points: `ios/Sources/App.swift`, `macos/Sources/App.swift`.
Shared presentation: `DesignSystem.swift`, `HomeSettingsViews.swift`, `ProfileViews.swift`, `DNSViews.swift`, `CheckViews.swift`, `VerificationViews.swift`, `FilteringViews.swift`, `IPDiscoveryViews.swift` under `ios/Sources`.
Diagnostics/application integration: `PublicIPProbe.swift`, `ConnectionVerification.swift`, `FilteringDiagnostics.swift`, `NetworkDiagnostics.swift`, `Core.swift`, `TunnelController.swift`.
Tests: `ios/Tests/VerificationTests.swift`, `ios/Tests/IPProbeTests.swift`.
Build integration: iOS project configurator/test/release version checks; macOS build, bundle and release version scripts.

## Launch

- iPhone: installed VayuSetu app; open Checks → Public IPv4 / IPv6 → Measure IPv4 & IPv6. Keep the VPN connected when testing its route. Open Connection Verification separately to compare with provider-supplied expected exits.
- Xcode: open `ios/VayuSetu.xcodeproj`, select VayuSetuVPN, team X4MH29QNRS and the connected iPhone; Run.
- Mac: open the DMG under `macos/dist/release`, move VayuSetuVPN into Applications, then open it. Approve its network extension when macOS requests it. The DMG is Developer ID signed but is not yet notarized; no security protections are disabled by the delivery scripts.

Sources: https://www.ipify.org/ ; https://www.ident.me/ ; https://docs.controld.com/docs/check-if-dns-is-working ; https://developers.cloudflare.com/cloudflare-one/traffic-policies/dns-policies/test-dns-filtering/

## Final artifacts

- `ios/dist/release/VayuSetuVPN.ipa` SHA-256: `cc63a862ef83a107249f6e3ec13079309fafc1ce1b2f335f5ce8eeb64ef59cff`.
- `macos/dist/release/VayuSetuVPN-0.4.0-macOS.dmg` SHA-256: `fbed359fb0d3379b1d2b4fb135f8ec718549677ee97234d72fd511258c16dff9`. DMG checksum verified; Developer ID signed, not notarized.
- Mac collapsed dashboard visually inspected: connection and verification cards fit the window with visible trailing controls.

Hardware testing is pending the user reconnecting the VPN on Wi-Fi and subsequently switching to cellular. The currently installed corrected build includes a debug-only original-request control for same-route comparison. The available disconnected baseline is not evidence of a tunneled IP response.
