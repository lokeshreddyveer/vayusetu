# iOS interaction audit — 12 October 2026

Scope: quality of existing Home, Profiles, DNS, Adblock and Settings flows. No additional protocol engine or security feature was introduced. This is a bounded audit, not a claim that every possible device/network/permission state is flawless.

## Internal flow reviewed

| Surface | Owner and behavior | Evidence boundary |
| --- | --- | --- |
| Home | AppStore orchestrates the selected profile; TunnelController observes OS state and samples extension counters. | Tunnel established is separate from independent protection verification. |
| Profiles | WireGuard uses NETunnelProviderManager; native IKEv2 uses NEVPNManager. Validate before disconnecting; serialize changes; read back saved preferences before startup. | QR/import syntax acceptance does not prove server connectivity. OpenVPN remains unavailable. |
| DNS | Keychain-backed resolver profiles; WireGuard encrypted DNS and OS DNS-only configuration are separate. Native IKEv2 retains server-managed DNS. | A selected endpoint or successful response does not prove device-wide DNS identity/path/filtering. |
| Adblock | Validated subscriptions/custom rules compile to a staged Safari content-blocker package. Busy operations are serialized and prior rules survive failed updates. | OS extension enablement, reload acknowledgement and actual rule effectiveness remain distinct. Safari rules do not filter other apps. |
| Settings | Native destinations expose permissions, routing, recovery, logging and encrypted backups. Destructive actions retain confirmation. | Accepted routing settings are not packet-capture proof. OS-required exceptions remain explicit. |

## Confirmed fixes

- Replace stale connection notifications on opposite state changes instead of suppressing reconnection updates for 30 seconds. Clear pending/delivered status notices when disabled.
- Protocol handoff uses stage-specific sanitized error codes; the owned native adapter is disabled and read back before WireGuard startup. No routing flag, DNS policy, certificate validation or credential is weakened.
- A delayed notification permission prompt cannot override a later off choice.
- DNS selection controls visibly disable during VPN/check/DNS operations; no misleading enabled row that silently ignores a tap. Search has a no-results state.
- DNS deletion waits for completion and retains the editor on failure; connection operations are blocked during deletion.
- Connection Details identifies IKEv2 server-managed DNS and does not show the unrelated selected WireGuard endpoint.
- Root DNS explanations are shorter; full mode/compatibility explanation remains in Advanced DNS Settings.
- Remove duplicate disclosure arrows from native list navigation and hide Recovery scroll indicators.
- Filter edits/import/removal controls disable during application. JSON export errors become visible.

## Validation

All 351 core/routing/WireGuard/lifecycle/backup/verification/IP/manual/QR/profile contract checks passed, including five new activation-recovery assertions. These do not prove live leak protection.

First hardware run: 3 passed, 1 failed. The failure stayed on Filter Health during a system-call interruption while attempting a Settings-tab tap. The rerun asserts the Settings destination before searching and repeats an interrupted tap once. No hidden app failure was converted into a success.

Final source builds succeeded. Hardware navigation evidence: five-tab navigation/editor cancellation passed; permissions passed; filter-list/custom-rule/filter-health/encrypted-backup navigation passed; all 15 Settings destinations and back actions passed (93.682 seconds). Some earlier runs were interrupted by phone calls, notification banners or the OS VPN consent alert. Their failed result bundles are retained; those runs are not counted as passes.

Live switching reproduced a native setup rejection (`NEVPNErrorDomain:1`). Avoiding redundant preference writes to an already stopped WireGuard adapter allowed WireGuard → IKEv2 to establish in the next measured run. The reverse switch still failed: a request was recorded but no new extension startup appeared, followed by read/write error 5 and rollback error 1. The final correction disables and reloads the owned native adapter before WireGuard startup. Only VayuSetu's WireGuard registration was rebuilt, preserving saved profiles and credentials. After unlocking, both final cycles failed at native startup with error 1. A second pair using fresh WireGuard manager objects and disabling/read-backing the old WireGuard adapter also failed. The final implementation adds at most two registration reloads for invalid/stale activation errors, revalidating identity, credential reference and strict routing/on-demand policy on each attempt. This last correction compiled, but its device test was blocked before app launch by iOS developer signing verification; it has not demonstrated successful switching. Both directions must pass before reporting the switch fixed.

Results: `ios/build/tab-audit-20261012.xcresult`, `tab-audit-final-20261012.xcresult`, `interaction-live-audit-20261012.xcresult`, `ike-switch-audit-retry-20261012.xcresult`. Additional runs: `profile-switch-final-20261012.xcresult` and `profile-switch-fresh-20261012.xcresult` (switch failures); `profile-switch-bounded-20261012.xcresult` (blocked at app launch by signing verification).

## Remaining coverage

The user explicitly authorized live switching after the call ended. The phone was unlocked; latest validation is blocked by iOS signing verification, affecting both runner and app. Local deep/strict signature verification passed and an in-place reinstall succeeded without deleting user data. The user was asked to turn VPN off and report the exact phone alert. OS notification delivery, destructive deletion rollback under OS/Keychain failure, permission-denied/revoked variants, large Dynamic Type, VoiceOver, cellular transitions and independent packet-path/leak verification require additional evidence. Existing earlier QR optical recognition and VPN startup results are historical evidence, not new test results from this audit.

## Sources checked

- [Apple VPN routing and system exceptions](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic)
- [Apple tab-bar design](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Safari blocker state versus reload](https://developer.apple.com/documentation/safariservices/sfcontentblockermanager)
- [Remove delivered notifications by identifier](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removedeliverednotifications(withidentifiers:))
- [SwiftUI toolbar visibility](https://developer.apple.com/documentation/swiftui/view/toolbarvisibility(_:for:))

Changed source: TunnelController.swift, Store.swift, DNSViews.swift, HomeSettingsViews.swift, ArchitectureViews.swift, FilteringArchitectureViews.swift, PrivacyFeatureViews.swift; test coverage: UITests/LaunchTests.swift. All under ios/ in this project.

- [Apple VPN invalid-configuration error](https://developer.apple.com/documentation/networkextension/nevpnerror-swift.struct)
- [Apple Personal VPN entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.vpn.api)
- Activation reload behavior also reviewed in the bundled upstream WireGuard `TunnelsManager.swift`; no vendor source was changed.

## Reopened-app validation

The user opened the app and automated launch succeeded. The final source then passed one full WireGuard → IKEv2 → WireGuard device test (`profile-switch-reopened-20261012.xcresult`, 54.948 seconds, 0 failures). Screenshots inspected in `docs/verification-switch-reopened`. No activation-reload warning was needed in this successful run, so the bounded recovery branch itself remains unit-tested rather than observed repairing a live rejection. A separate repeat was blocked at launch by iOS signing verification (`profile-switch-repeat-20261012.xcresult`). Two-cycle validation is pending VPN-off/app-open confirmation and will run within one launch. Earlier failed and blocked result bundles are retained.


### Final two-cycle device result

User confirmed VPN off, app open and phone unlocked. `profile-switch-two-cycles-20261012.xcresult` passed **two complete WireGuard → IKEv2 → WireGuard cycles within one app launch**: 1 test, 0 failures, 104.560 seconds. The test checks protocol identity, OS tunnel-established state and five-second stability after each transition. The earlier single-cycle result also passed. Final observed adapter is us-den/WireGuard. Screenshots exported to `docs/verification-switch-two-cycles`; the earlier successful native and WireGuard screenshots were visually inspected. Temporary live-test opt-in was removed afterward.

This verifies the tested profile handoff on this Wi-Fi session. It does not prove long-duration stability, cellular transitions, IKEv2 traffic counters, exit identity, DNS filtering or leak isolation. Intermittent developer-build signing rejection on a separate app relaunch remains unresolved; starting the run with VPN off and app open allowed the in-session test to complete. Initial startup rejection was configuration-invalid after read-back; the exact OS cause and effect of each individual mitigation cannot be isolated from this evidence. The bounded activation reload branch did not need to fire in the successful single-cycle run and is independently covered only by its five unit assertions. No TestFlight upload was performed.
