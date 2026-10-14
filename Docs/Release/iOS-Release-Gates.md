# iOS release handoff — 0.4.0

## Current products

Preview and full-VPN Debug unsigned app bundles in ios/dist/. Shared core package linked into both app schemes. Signed preview installed on the connected iPhone; launch refused while locked. No full-VPN signed IPA or upload exists.

## Confirmed blocker

The existing Personal Team cannot provision Network Extensions. A fresh device signing attempt failed for both app and extension. Configure an enrolled team with packet-tunnel and shared Keychain authorization for both targets before actual VPN testing.

## Remaining gates

1. Unlock and inspect the installed preview: circular control, profile creation/import/editing, resolver profile CRUD, accessible navigation and redacted exports.
2. Provision the full app/extension, import an authorized VPN configuration and resolver endpoint in the app; keys should not be sent in chat.
3. Validate Keychain sharing, actual handshake, independently confirmed provider exit, DNS path/filtering, IPv6 enforcement and prohibited fallback.
4. Inject tunnel/resolver failure, cancellation, preference/Keychain failures, sleep/wake and network changes. Confirm retry budget, rollback, history and honest verdict reset.
5. Complete advanced direct-DNS isolation feasibility; it remains unsupported until proven. Do not enable broad resolver-IP bypass.
6. Run UI/accessibility/performance and long-session checks on supported hardware. Complete the remaining package extraction and authentication capabilities if required for the selected resolver.
7. Run ios/scripts/release/archive-ios.sh with the authorized team; validate exported IPA and clean installation. Prepare TestFlight manually only after release gates pass.

The workflow file is ready for an owner-configured runner; no GitHub run or publication occurred. The full supplied target architecture is not represented as complete.
