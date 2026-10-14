# VayuSetu v1.3 implementation and evidence

Source project: `~/Documents/VayuSetu`. Both apps reuse the native shared screens and portable policy/filtering package. Source backup: `Source-Backups/v1.3-20261011-183932`.

## Implemented

- Five primary destinations: Home, Profiles, DNS, Adblock, Settings. Checks remain available through Home and Settings.
- Separate desired and observed protection state, evidence source, observation timestamps and stale-state handling. No inferred protection from successful connectivity.
- Connection Details with observed duration, actual WireGuard counters and rates only when a recent derivative sample exists. Unknown server IP/interface stays unavailable.
- Profile sorting, validated WireGuard editors, additive file import, duplicate detection, redacted export, serialized switching and Connection Rules.
- Encrypted DoH/DoT resolver profiles in Keychain, searchable resolver management, DNS Security and DNS Diagnostics; OS encrypted DNS-only with conflict handling and managed configuration removal.
- Adblock overview with Filter Lists, list details, Filter Health, Custom Rules (allow/block, exact/subdomain scope, enabled state), local rule-match evaluation and honest available statistics.
- Opt-in HaGeZi/OISD/StevenBlack subscriptions, bounded HTTPS updates, ETag/checksum, parser rejection counts, atomic Safari publishing, reload acknowledgement, persisted rollback journal. No automatic list selection or silent truncation.
- Safari content-blocker extension on both platforms. OS enablement, package readiness and actual enforcement effectiveness are distinct.
- SQLite privacy metadata/events, category-filtered local activity and retention settings. No browsing/query history or telemetry.
- Native Privacy Lock with explicit temporary relaxation/restoration, conflicts/capability status, Extension Status, notifications, appearance/accessibility, optional onboarding and Emergency Reset.
- Password-encrypted backups default to profile names, custom rules and list names. Keys, profile network addresses, resolver URLs and list URLs require explicit credential opt-in. Additive restoration generates fresh identities and never automatically connects or enables new lists. Source-free profile metadata requires reimport; source-free list names remain informational. Existing data is preserved. Filter restoration errors are reported separately from committed profile restoration.
- Optional iOS Live Activity with foreground-only creation/restart, local sampled content and expiry handling. No backend or push channel.
- Independent public IPv4/IPv6 discovery remains separate from exit verification and leak checks. Optional explicit ASN lookup, bounded response handling and short-lived in-memory cache.

## Material fixes

Xcode's generated property lists omitted runtime App Group/Keychain keys despite build-setting declarations. Explicit plist templates restore those keys; the corrected physical iPhone build accesses its Safari shared container and acknowledges reload. Legacy authorized Keychain credentials migrate on read. macOS uses the provisioned team's platform App Group format; iOS uses its separately authorized group. All embedded extension versions match the host.

## Capability boundaries

WireGuard is the working tunnel backend. OpenVPN/IKEv2, tunnel-local DNS interception, DNS-before-VPN direct routing, cosmetic ABP syntax and speed-test backends are not implemented and are not offered as functioning controls. QR scanning remains a future import method; file/clipboard/native editor imports work. The resolver library is currently the searchable DNS overview, not a separate duplicated screen. Provider presets are not selected automatically. Preference backup/migration is not included in this release; existing local preferences are preserved during restore.

Strict routing uses Apple's supported controls and may have OS exceptions. It is not a universal kill switch. A connected tunnel or DNS response does not establish leak isolation. Safari does not expose individual blocked-request counters. No military-grade or complete-protection claim is made.

## Verification

Evidence is retained under `docs/verification-v1.3` and the platform build result bundles. This report is updated with final build/device outcomes before delivery. Existing test coverage validates policy/configuration, not real packet paths.

Pending runtime gates: connected Wi-Fi/cellular observations, independent DNS route/isolation, actual Safari blocking, OS DNS-only coexistence, maximum capacity, Live Activity expiry, captive networks and failure-transition leak behavior. Runtime observations cannot substitute for controlled external verification.

### Final build/test outcomes — 2026-10-11

- iOS full Release archive: **passed**, 0.11.0 (16), host + tunnel + Safari + Live Activity signatures/profiles/versions/capabilities verified.
- macOS universal VPN build: **passed**, 0.6.0 (8), host + tunnel + Safari Developer ID signatures and platform App Groups verified. Both architecture UUIDs and genuine debug info match all three archived components.
- macOS DMG: Apple notarization **Accepted**, ticket stapled and validated, checksum verified. `macos/dist/release/VayuSetu-0.6.0-macOS.dmg`.
- Regression runner: **275 assertions passed** (50 core, 77 route, 8 WireGuard policy, 16 runtime/evidence, 39 feature/backup, 30 verification/filter evidence, 55 independent IP checks).
- Portable XCTest: **17 tests passed**, including disabled-rule precedence and legacy decoding.
- SQLite/list-default/ASN runner: **20 checks passed**.
- Physical iPhone UI: four tests passed in `ios/build/v1.3-screen-ui-results.xcresult`; one failed because a button became a navigation row. Corrected selector rerun in `ios/build/v1.3-screen-safari-results.xcresult`: **passed**. All five distinct test cases now pass, covering repeated launch, five tabs, editors, bootstrap rejection, strict policy controls, diagnostics scrolling, filter destinations, default credential opt-out and Safari evidence labels.
- Screenshots inspected: native tabs/icons render and filter lists stay unchecked. Full accessibility/Dynamic Type/device-size QA remains pending. Some navigation labels currently draw an extra chevron; visual polish remains necessary.
- Earlier corrected iPhone build acknowledged Safari reload with OS disabled. The **latest** runtime check reported OS state unknown and no reload acknowledgement. That is the current evidence; no actual Safari enforcement success is claimed. Review Safari extension registration/enablement and rerun before relying on rules.
- Connected Wi-Fi/cellular testing is **pending**. The copied IP report was from an older run and was explicitly excluded from current-build evidence.
- Final Debug build is installed on the user's iPhone. The test is waiting for a stable connected VPN. No new TestFlight upload occurred.
- Automatic replacement of `/Applications/VayuSetu.app` was blocked by the existing installation's ownership permissions. The previous application was preserved in the source-backup folder; staging was removed. Install the notarized DMG manually using macOS's normal Applications replacement prompt. The final macOS runtime is not marked verified from the older installed app.

### Artifacts

- iOS archive: `ios/build/v1.3/VayuSetu-iOS.xcarchive` (Xcode distribution export required for TestFlight).
- macOS archive: `macos/build/v1.3/VayuSetu-macOS.xcarchive` (Developer ID distribution; not a Mac App Store/TestFlight archive).
- macOS installer: `macos/dist/release/VayuSetu-0.6.0-macOS.dmg` and SHA-256 sidecar.
- Native device screenshots and test reports: `docs/verification-v1.3`.

### Connected Wi-Fi follow-up — October 11, 2026, 10:05 PM CDT

Current installed iPhone build measured a stable established tunnel on Wi-Fi. Independent IPv4 fallback (`4.ident.me`) returned an address in 839 ms. Primary IPv4/IPv6 ipify requests failed because system DNS returned only unspecified/loopback destinations. Queries to the configured encrypted resolver independently returned blocking responses for both ipify hostnames, in both A/AAAA queries. URL variants reproduced the same failure; no resolver or route was substituted. This supports DNS policy blocking as the ipify failure cause.

IPv6 fallback reported connectivity unavailable; no IPv6 address was obtained. That is not a passed IPv6 leak check. WireGuard counters increased during the probes, but concurrent traffic may contribute. Saved OS configuration showed default capture for both families, zero excluded routes, encrypted DNS and IPv6 capture/drop requested. The observed `enforce routes` setting was false despite strict capture being true; configuration acceptance does not establish isolation. VPN exit identity, DNS route and failure isolation remain unverified.

The secret-free report is `docs/verification-v1.3/ios-vpn-wifi-20261011.txt`. Cellular follow-up is awaiting the user's network switch. macOS Developer ID signatures/App Groups and the stapled notarization ticket were revalidated in this follow-up; macOS live VPN behavior was not tested.

### DNS website/provider verification follow-up

iOS 0.11.1 (17) and macOS 0.6.1 (9) add selected-provider-first native identity checks, plus embedded BrowserLeaks, DNSLeakTest and all five official provider websites. Cloudflare requires its actual browser test; it is not represented as a native identity pass. Provider errors and schema changes stay inconclusive. See `docs/Testing/DNS-Provider-and-Website-Checks.md` for methods, sources, live Mac adapter results and limitations. 295 regression assertions passed. iOS signing/archive and macOS signed/notarized DMG passed. iPhone installation and website UI execution await phone availability; these results do not validate device-wide DNS isolation.
