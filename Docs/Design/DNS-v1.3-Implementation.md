# DNS v1.3 — incremental implementation

The supplied DNS architecture is the target. Existing resolver persistence, WireGuard policy, IKEv2 adapter and independent OS encrypted-DNS controller remain the enforcement owners.

## This step: overview card and configuration summary

- Preserve the existing DNS header and its Advanced destination.
- Compact status card uses `AppStore.protection(.dns)` and shared observed states, with neutral inactive/unknown, amber unverified/limited/applying, red error and green only for canonical active evidence.
- Show the effective mode/source: System DNS, independent encrypted DNS, or VPN-managed DNS. Native IKEv2 explicitly shows server-managed DNS and unverified encryption; it never presents the saved Control D resolver as applied.
- Shared state reports applying while DNS operations run and limited for native server-managed DNS. WireGuard configuration intent does not invent a verification timestamp.
- Current configuration separates required transport configuration from observed behavior. No diagnostic timestamp or successful behavior is fabricated.
- Change Resolver navigates to saved resolver browsing. Changes remain locked while VPN/DNS operations are active; opening the library preserves the current connection.
- No automatic diagnostic traffic, resolver substitution, plaintext fallback or new protocol engine.

## Subsequent steps

The root still contains previous resolver-management controls below the new summary. The mode buttons are now consolidated into a compact selection destination. Preset library/details, diagnostic-provider consent/history and supported encrypted fallback need separate implementation/validation. Local filtering stays unavailable until an enforcement mechanism is implemented. No unsupported toggle will be added.

## Device validation — 12 October 2026

Installed on the user’s unlocked iPhone with VPN off. `dns-step2-device-final-20261012.xcresult`: 2 tests, 0 failures (22.706 seconds). Verified DNS header/Advanced Settings → Security navigation, Change Resolver target of at least 44 points, observed mode/resolver accessibility, saved resolver library/search, back navigation and Advanced Settings return. Final screenshot visually inspected in `docs/verification-dns-step2-final/DCEA77DB-0250-4CB5-8801-D2771B5F2E06.png`; no stray card disclosure arrow or clipped status text.

The initial run passed the header check but failed to find the card action because a parent accessibility identifier was inherited by all children. Removed that parent identifier, retained distinct control identifiers and made the card action a native button-driven navigation destination. Initial failed result bundle is retained. VPN/active DNS states, very large Dynamic Type and VoiceOver were not device-tested in this step; no protection or packet-path verification is inferred from UI navigation.

## Step 3 — compact DNS mode selection

- Replaced iOS inline enable/disable buttons with a compact DNS Mode destination; retained the macOS layout.
- Four choices explain System DNS, independent encrypted DNS, VPN-managed DNS and unavailable local filtering. Unsupported local filtering is inspectable for its explanation but cannot be applied.
- Changing independent DNS requires VPN disconnected, no active connection/diagnostic operation, readable OS settings and no foreign DNS configuration. Encrypted mode validates the saved endpoint and optional bootstrap addresses.
- Confirmation precedes mutation. Preferences reload and compatibility revalidation occur after confirmation, before any change. Cancel does not mutate the controller. Selecting VPN-managed mode does not start or stop a tunnel.
- System DNS can remove a saved but not enabled VayuSetu encrypted configuration. Successful saving is distinguished from iOS user enablement; actual transport and filtering remain unverified.
- Intent persistence now follows successful OS save/removal. A rejected OS operation preserves the prior intent. Configuration/storage errors remain visible; no plaintext fallback is added.
- Added device UI coverage for minimum touch size, unavailable modes, confirmation/cancel and back navigation. This test has compiled but has **not run**: Xcode currently reports the authorized iPhone unavailable. No install, screenshot verification or device transition success is claimed.

Validation: final signed generic-iOS build-for-testing succeeded. Privacy storage/list defaults/ASN regression suite: 20 checks passed. Logs: `/tmp/vayusetu-dns-step3-build.log` and `/tmp/vayusetu-dns-step3-privacy.log`. Real DNS save/remove transitions, active VPN conflicts and accessibility/visual layout still require device validation. Apple documents user enablement at https://developer.apple.com/documentation/networkextension/nednssettingsmanager/isenabled .

### Step 3 follow-up device evidence

During the Profiles refinement session, the iPhone reconnected. `profile-refinement-final-20261012.xcresult` passed DNS mode selection/blocked choices/confirmation cancellation/back navigation. One prior run used the wrong accessibility element type for the combined current-mode row; the test query was corrected. Screenshot `docs/verification-profile-refinement/5C9A93E3-2BB1-4660-B656-912C1C270477.png` visually reviewed. No actual DNS save/removal was executed by this UI test, and no VPN path or filtering verification is inferred.
