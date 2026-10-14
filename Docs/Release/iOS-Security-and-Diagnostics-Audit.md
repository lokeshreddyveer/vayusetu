# VayuSetu iOS security and diagnostics audit

Date: 2026-10-11. Candidate: 0.9.0 (13), development signed, team X4MH29QNRS. This candidate has not been uploaded to TestFlight. Existing macOS 0.5.0 (6) and iOS TestFlight build 12 are not replaced by this source change.

## Architecture and enforcement

Existing SwiftUI navigation, stored profiles, encrypted DNS and WireGuard integration are preserved. App services own selection and orchestration; the packet-tunnel extension owns accepted route/DNS configuration. Shared `VayuSetuCore` owns lifecycle/evidence contracts. WireGuard remains the only implemented tunnel provider; adding a selectable name does not implement another protocol.

Profile validation requires a valid IPv4 interface and full IPv4 route. Canonical default-route recognition accepts equivalent IPv6 spelling. A profile with native IPv6 must have appropriate addressing/default routes and MTU >= 1280. Otherwise backend IPv6 routes are removed and the OS IPv6 capture route is configured to deliver IPv6 to a backend without a matching peer route. This requests restriction; it does not independently verify blocking.

VPN → DNS retains all-domain native encrypted DNS and no resolver-IP bypass exceptions. DNS → VPN remains explicitly unsupported, rather than quietly applying a different flow. Configuration saves are read back before starting, including strict capture, route enforcement and LAN exceptions. Required policy failure cancels startup rather than accepting weaker settings. App retry exhaustion no longer silently disables a user's OS on-demand setting. Explicit user disconnect can disable on-demand.

Versioned, bounded app/extension statistics retain legacy decoding. Accepted-settings evidence is recorded only after successful OS completion and invalidated on settings withdrawal/stop; revision guards prevent late callbacks from reviving it. Numeric startup/disconnect breadcrumbs are bounded and redact arbitrary error domains. Keychain stores credentials; exports do not contain private keys, DNS tokens, raw configurations or NSError userInfo.

Apple's routing controls include platform-required traffic exceptions; accepted configuration is not equivalent to independently observed packet paths. See [Apple VPN routing](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic).

## Public-IP implementation and root-cause findings

Before modification, both ipify requests used HTTPS family-specific hostnames with `?format=json` and an empty URL path. The independent family fallback used 4.ident.me / 6.ident.me. Responses were parsed/validated as IP addresses, request/resource deadlines were already bounded at 8/10 seconds, with up to two attempts per family and a 4 KB body limit. All requests used URLSession's default route and system TLS. The reported -1000 error had no distinct classification; it fell into generic request failure.

The candidate builds URLs with URLComponents, an explicit root path and queryItems, and validates HTTPS scheme, allowlisted host, root path, query, credentials, port and fragment before transport. Sanitized output now records the exact public service URL, duration, timestamp and allowlisted NSError domain/code chain. IPv4 and IPv6 remain independent; fallback is operated separately by ident.me. Invalid URL, DNS, TLS, HTTP, parsing, family mismatch, timeout, cancellation and unavailable connectivity are distinct. No route/interface binding, DNS bypass or certificate exception was introduced.

**Confirmed root cause in the reproduced configuration:** the selected encrypted resolver sinkholes both `api.ipify.org` and `api6.ipify.org`. On connected cellular, its A and AAAA replies for both names are zero-address blocked responses with RCODE 0. System getaddrinfo independently returns two destinations, both unspecified/loopback, for each host. URLSession rejects the resulting unusable destination with NSURLErrorDomain/kCFErrorDomainCFNetwork -1000 despite valid, locally validated URLs. Both original empty-path and canonical root-path requests exhibit the same failure. Disconnected Wi-Fi requests succeed. The defect was attributing this resolver-policy failure to a generic request/URL problem, not a demonstrated malformed URL string.

**Fix:** preserve the configured DNS/VPN policy, report DNS destination unusable with sanitized measured evidence, and use the independent family-specific ident.me fallback on the same default route. IPv4 discovery succeeds on the VPN. The app does not silently unblock ipify, resolve it through another provider, substitute an IP literal or weaken routing. Primary-provider success remains unavailable under this resolver policy; a filtering-policy change would be a separate user decision.

Public address discovery is separate from expected VPN exit attribution, DNS path verification and leak protection. A public-address response cannot satisfy the independent IPv4 exit-verification contract. IPv6 -1009/unavailable is not reported as blocking passed. Family-specific service hostnames and response validation cannot force an IPv4 socket on NAT64; OS translation is explicitly documented.

## Diagnostics and targeted UI changes

- Disconnected baseline capture requires a disconnected VPN and available network, with an explanatory disabled state. Baseline comparisons require a valid family, same network-type label and age <= 15 minutes. IP differences alone are not leak proof; SSID/provider changes within a network type remain a limitation.
- Verification separates public connectivity, DNS evidence and Security & Routing. DNS provider identification does not prove transport path. Counter changes are weak correlation and cannot distinguish concurrent traffic or prove DNS isolation.
- Filtering records target/reference A and AAAA responses, RCODE, latency, date and classification reason. Missing/invalid reference or empty controls is inconclusive. Reference queries are diagnostic-only; no system-DNS replacement/fallback occurs. Controlled test names must be configured for ad/tracker categories. No browser or blocking-percentage score is asserted.
- Checks consolidates supported measurements and eight displayed check outcomes; unresolved route/isolation items remain explicit. Coverage is not a privacy/security percentage.
- Inline native navigation titles replace overlapping large detail headers. IP/verification/filtering actions scroll with the list rather than obscuring results above the tab bar. Scroll indicators remain hidden by existing native view styling.
- DNS/quality results are cancelled or invalidated after configuration/network transitions so old successes do not survive a new route.

## Changed files

Networking/enforcement: `ios/Sources/Core.swift`, `RoutePolicy.swift`, `Secrets.swift`, `TunnelController.swift`, `Store.swift`, `NetworkDiagnostics.swift`, `PublicIPProbe.swift`, `ConnectionVerification.swift`, `FilteringDiagnostics.swift`; `ios/Tunnel/PacketTunnelProvider.swift`, `WireGuardConfigPolicy.swift`.

UI/test runner: `ios/Sources/App.swift`, `CheckViews.swift`, `IPDiscoveryViews.swift`, `VerificationViews.swift`, `FilteringViews.swift`; `ios/UITests/LaunchTests.swift`.

Validation/release: `ios/Tests/CoreTests.swift`, `RouteTests.swift`, `WireGuardPolicyTests.swift`, `RuntimeTests.swift`, `FeatureTests.swift`, `VerificationTests.swift`, `IPProbeTests.swift`; `ios/scripts/security-scan.sh`, `.github/workflows/ios.yml`, `ios/VayuSetu.xcodeproj/project.pbxproj`, `ios/scripts/configure-project.py`, `ios/Vendor/PATCHES.md`. Existing initial-source backups are retained under `Source-Backups/`.

## Validation evidence

Results below are updated as hardware measurements complete. Unit contracts are not packet capture, visual QA or failure-isolation proof.

- Contract suite: 227 checks passed (50 core, 34 route/IPC/log redaction, 8 WireGuard policy, 16 lifecycle, 34 feature/counter, 30 verification/filtering, 55 IP).
- Shared package: 3 XCTest cases passed, 0 failures.
- Signed iOS development build: succeeded. codesign deep/strict verification and app/extension team, profile, tunnel-entitlement and shared-Keychain checks passed. Final candidate reinstalled on hardware, with the final system-DNS classifier confirmed on both cellular and Wi-Fi.
- Hardware UI retry: 1 test passed, 0 failures, 12.137 seconds on the actual iPhone. Both exact screenshots were exported and visually inspected: inline detail titles are separated from the back control, the IP action is visible above the tab bar, and the filtering reference explanation/disabled action are visible. Earlier pairing failure and a stale cached profile prevented initial attempts; fresh derived build and repaired pairing resolved these. Results: `ios/build/Security-UI-13-Retry.xcresult`; screenshots: `Evidence/iOS-0.9.0-13/UI/`.
- Go module integrity: all modules verified. Pinned govulncheck 1.8.0 completed actual iOS/arm64 source analysis. GO-2026-5932 is retained as a module-only advisory for x/crypto OpenPGP; affected OpenPGP packages are absent from the actual iOS dependency import inventory. No package/call-level vulnerable finding was emitted. This is known-advisory analysis, not a cryptographic audit. Raw JSON/inventory are under `ios/build/security-reports/`. See [Go vulnerability scanning](https://go.dev/doc/security/vuln/).

### Real iPhone measurements

Device: user's iPhone 18 Pro Max; actual signed candidate installed. Sanitized evidence omits public addresses and personalized resolver URLs.

| Network / VPN | Result | Evidence |
| --- | --- | --- |
| Wi-Fi, disconnected | IPv4 and IPv6 ipify responses succeeded (207/166 ms); old URL controls also succeeded (184/130 ms). | `Evidence/iOS-0.9.0-13/wifi-disconnected.txt` |
| Wi-Fi, connected | Stable 08:56:58Z run: ipify both families rejected with -1000 (58/57 ms); ident.me IPv4 succeeded (788 ms), IPv6 unavailable -1009 (53 ms). Old URL controls also returned -1000. Extension accepted both default routes, zero excluded routes, encrypted all-domain DNS and IPv6 capture/drop intent. | `Evidence/iOS-0.9.0-13/wifi-vpn.txt` |
| Cellular, connected, initial reproduction | Stable 09:00:05Z run: ipify both families -1000 (135 ms); ident.me IPv4 succeeded (1287 ms), IPv6 unavailable -1009 (88 ms). Old URL controls also failed. Extension accepted the same required policy. | `Evidence/iOS-0.9.0-13/cellular-vpn.txt` |
| Cellular, connected, final DNS diagnosis | Stable 09:10:32Z run: both ipify names classified as DNS destination unusable (226 ms each); system DNS returned only unusable destinations and configured encrypted DNS returned zero-address A/AAAA answers (RCODE 0). ident.me IPv4 succeeded (1437 ms), IPv6 unavailable -1009 (86 ms). | `Evidence/iOS-0.9.0-13/cellular-dns-diagnosis.txt` |
| Wi-Fi, connected, final DNS diagnosis | Stable 09:13:00Z run: both ipify names classified as DNS destination unusable (70 ms each); system DNS returned only unusable destinations and configured encrypted DNS returned zero-address A/AAAA answers (RCODE 0). ident.me IPv4 succeeded (772 ms), IPv6 unavailable -1009 (62 ms). | `Evidence/iOS-0.9.0-13/wifi-dns-diagnosis.txt` |

## Remaining limitations and next priorities

1. **P0, independent isolation:** No controlled external observer or packet capture currently proves IPv4/IPv6/DNS cannot bypass. No tunnel-crash/failure-injection or reliable Wi-Fi↔cellular security test has passed yet. Continue showing established/unverified; do not label protection complete.
2. **P0, platform DNS limits:** Native all-domain encrypted DNS does not stop arbitrary application DoH/direct sockets by itself. Resolver hostname bootstrap uses system getaddrinfo before the tunnel and has no independently controlled bootstrap/pin policy. No DNS-only direct route is supported.
3. **Resolved, IP diagnostic root cause:** Original and final measurements on Wi-Fi and cellular confirm sinkholed ipify destinations. IPv4 fallback and final DNS-specific classification work on both networks. ipify itself remains blocked by the chosen resolver policy; primary-provider access is not restored by bypassing that policy.
4. **P1, exit/provider proof:** Expected exit IP remains user/provider-supplied configuration; no provider API adapter independently attributes it. Disconnected IP comparison is evidence, not security proof.
5. **P1, filtering controls:** Real configured provider/reference filtering comparisons have not been verified for every category. Inconclusive controls remain inconclusive.
6. **P2, reliability/performance:** Captive portals, NAT64, crash/reassertion, sleep/wake, battery, sustained throughput, memory and long-run packet loss require a dedicated hardware test session. HTTPS timing is not raw packet loss or sustained throughput.
7. **P2, release:** No build-13 TestFlight upload, macOS rebuild or App Store approval is claimed. Shared source changes need macOS runtime/regression validation before a new Mac release. An arm64 shared-source app typecheck passed; existing Mac distribution artifacts were not modified.

## Additional diagnosis in final source

When a locally validated URL receives -1000, the final transport now observes only that allowlisted public service hostname through system getaddrinfo, with a four-second observation deadline and single-resume guard. All-unspecified/loopback answers are classified separately as DNS destination unusable; partial, failed or timed-out observations retain uncertainty. Raw addresses are not exported, and no resolver/IP/route is substituted. Unit coverage includes expanded IPv6 unspecified spelling, valid global addresses, mixed answers, timeout uncertainty and independent fallback. Hardware confirmation of this final observation passed on both connected cellular and Wi-Fi. The OS resolver worker may finish after the observation deadline; it frees its own results and cannot overwrite an already-completed observation. At most four system-DNS workers can remain outstanding. Unspecified/loopback addresses returned as a service exit response are rejected as malformed. The debug runner also compares A/AAAA answers from the selected encrypted resolver for these same public test hostnames; it exports only observations, RCODE and timing, not the personalized endpoint.


## Final disposition

The external-IP diagnostic defect is resolved for the reproduced resolver policy: valid ipify URLs are rejected because DNS supplies unusable sinkhole destinations; the app now explains that failure and completes IPv4 discovery via an independently operated fallback without a bypass. Final signed development candidate 0.9.0 (13) is installed on the actual phone and tested through the VPN on Wi-Fi and cellular. Raw sanitized evidence is retained beside this report. 227 contract checks, 3 shared XCTest cases and 1 real-device layout test passed. Two layout screenshots were inspected. No release upload was performed.

IPv6 connectivity is unavailable in this IPv4-only/capture-drop configuration. This outcome is consistent with the configured intent but does not independently establish secure restriction. DNS transport, leak prevention and crash/transition fail-closed guarantees remain unverified. Remaining P0 work needs controlled observers/packet-path evidence and failure-injection tests; the app continues to show tunnel established with verification pending.
