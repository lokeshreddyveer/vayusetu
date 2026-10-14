# Profiles review — first refinement pass

Source: user-supplied screenshot review dated 12 October 2026. This is an incremental refinement, not completion of every architecture recommendation.

## Implemented

- Connection Details now groups connection summary, session, server, protection and actions; raw policy evidence moves to Routing & Verification.
- Privacy Lock separates requested policy, accepted tunnel configuration and unverified isolation. Fresh, connected-session extension statistics are required before presenting accepted settings. Native IKEv2 reports unavailable route/DNS detail instead of extension evidence.
- WireGuard editor/details distinguish preserved imported DNS from the VayuSetu resolver requested on connect, and from accepted settings. Accepted encrypted settings do not identify a resolver or independently verify the query path.
- Renamed the existing IPv6 constraint to Require dual-stack WireGuard profile and explained that it validates the tunnel address/default route, not physical-network IPv6 or leak isolation. IKEv2 incompatibility remains enforced by existing connection code.
- Retained recovery controls; Emergency Reset explains preserved profiles/keys, network DNS afterward and recreation of system VPN configuration on reconnect.
- Removed redundant Profiles bottom Add action and disabled-looking selected-profile action. Profile editing has one Edit / Rename action with an explanation when locked.
- Removed custom chevron inside Connection Details native Privacy Lock navigation and native list detail links. Hide tab bar on detail screens and restore on return.
- IKEv2 editor untested-connection notice uses neutral information styling, separate from actual configuration errors.
- Compact evidence rows expand vertically for long values. Final spacing correction removes extra native list top/bottom insets.

## Validation

Signed iOS build-for-testing succeeded. Existing regression suite: 351 checks passed (configuration, routing, lifecycle/evidence, diagnostics, manual protocols, QR/IKEv2 and profile management).

Real iPhone: Profile Details/editor inspection passed (20.191 seconds) in profile-refinement-20261012.xcresult. Two initial added checks failed: wrong accessibility element type in DNS test; ancestor tab-bar visibility overrode detail hiding. Both were corrected. profile-refinement-final-20261012.xcresult then passed 2 checks, 0 failures (36.485 seconds): DNS mode confirmation/cancel, unavailable choices; Connection Details → Privacy Lock → technical evidence → reset information → back to root, hidden/restored tab bar. Tests did not execute a reset or connect a VPN.

Exported and visually reviewed Privacy Lock and DNS selection screenshots under docs/verification-profile-refinement. The screenshot exposed excess native list padding, prompting one final inset adjustment. The phone then disconnected before this final adjustment could be installed or device-tested. At that point the installed build and exported screenshots preceded the last spacing adjustment. This limitation was resolved by the follow-up device session below.

## Remaining architecture work

Per-profile DNS-policy choices are not implemented. Current behavior remains VayuSetu encrypted resolver for WireGuard and server-managed DNS for native IKEv2; no cosmetic Use profile DNS/System picker was added. Exact applied resolver identity, live DNS transport/leak isolation, Privacy Lock failure scenarios and actual Emergency Reset acceptance require further adapter work or controlled real-device tests. Large Dynamic Type/VoiceOver and all tab/editor flows were not comprehensively device-tested in this pass. No TestFlight upload.

Changed files: ios/Sources/ArchitectureViews.swift, ios/Sources/ProfileViews.swift, ios/Sources/TunnelController.swift, ios/UITests/LaunchTests.swift. DNS-mode code was already implemented in the previous step; its device test now passed.

## Follow-up acceptance — final spacing and editors

The iPhone reconnected on 12 October 2026. Installed the final spacing build and ran `profiles-review-spacing-editors-20261012.xcresult`: **3 tests, 0 failures, 55.125 seconds**. These cover WireGuard and native IKEv2 add/editor opening and cancellation; saved WireGuard profile details/edit/back navigation; compact Connection Details, Privacy Lock, technical evidence and reset-information navigation; hidden detail tab bar and restored root tab bar. No profile was saved/deleted, no VPN was connected, and no emergency reset was executed.

Exported final screenshots under `docs/verification-profiles-spacing-editors`. Visually reviewed Connection Details (`FC317576-0E8A-4416-9B15-D574C4129B83.png`), Privacy Lock (`E0985AD6-BE1C-4A5A-8769-1368A02E9927.png`), new WireGuard editor (`FF46E604-3BDB-4532-98C5-46B0A5043839.png`) and IKEv2 editor (`3DB71CBA-0414-455C-911B-6718EED0DA01.png`). Read-only rows are visibly shorter, Privacy Lock has one disclosure chevron, detail screens have no floating tab-bar obstruction, and the IKEv2 informational notice is neutral. Existing editor native inline headers remain intact. This is default-size portrait visual review, not comprehensive large-text/VoiceOver/keyboard acceptance.

Remaining architecture items above are unchanged. The prior 351 regression result is not represented as a new rerun in this follow-up; this session validates the final installed UI build.
