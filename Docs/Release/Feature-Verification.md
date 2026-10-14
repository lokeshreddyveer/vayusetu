# Feature expansion verification

2026-10-11, local Xcode 27 on the user's Mac.

## Completed

- 167 command-line checks: 50 profile/DNS core, 20 native routing, 6 WireGuard policy, 11 lifecycle/history compatibility, 31 backup/restore/quality/domain checks, 22 verification/filtering evidence checks and 27 IP diagnostic checks.
- Backup checks include randomized ciphertext, correct-password round trip, wrong-password rejection, tamper/truncation rejection, fixed KDF bounds, file/profile limits and validation.
- Restore checks simulate interruption, original metadata restoration, removal of originally absent metadata, cleanup limited to newly generated account IDs, retained journals when cleanup fails, and successful recovery retry. Test cleanup uses an injected stub and never touches real profile credentials.
- DoT route checks confirm the certificate server name, global match domains and absence of resolver bypass routes. Live DoT tunnel traffic remains unverified.
- Both universal macOS preview and VPN products compile, including the real WireGuard system extension. Local bundle checks pass.
- iOS 0.7.0/build 11 Release archive/export passes paid-team provisioning, app/extension signing, Network Extension and shared Keychain checks.
- macOS 0.4.0/build 4 Developer ID release signing and DMG verification pass. The mounted DMG contains the same signed release files, both arm64/x86_64 architectures and an Applications link.
- Mac preview opens. Settings visibly expose encrypted backup/restore, retry count, connection timeout and data alert controls. Diagnostics shows network-family/metering information, the quality test and advanced DNS query controls.
- A real Mac preview quality test completes with five successful HTTPS requests. The observed UI reports 81 ms mean, 56 ms timing variation and 0% failed requests; these are a single current-route sample, not guarantees or packet-loss metrics. Recent-check history is populated.

## Pending

- iPhone update completed after the user disconnected the tunnel and confirmed readiness. The corrected signed debug 0.7.0/build 11 installed and launched successfully. Two cold launches succeed; the app remains running and the Home screen preserves the selected VPN profile and DNS resolver. Crash inventory contains only the earlier 0.4.1 reports from 2026-10-10 19:37–19:38. No new crash report was observed.
- Home launch is verified on iPhone. New DNS/Settings screen interaction, backup dialogs and real tunnel/DoT/IPv6 behavior still need hardware verification.
- Independent DNS, leak, provider-exit, fail-closed and path-transition tests remain required.
- The Mac DMG is signed but not notarized or stapled. The signed Mac system extension has not been activated or tested on a clean installation.
- See Architecture/Implementation-Gaps.md for all unimplemented roadmap capabilities. This verification does not mean every Blueprint feature is complete.

## Current external-IP evidence

- Disconnected iPhone Wi-Fi: both families received valid ipify responses (220 ms IPv4, 173 ms IPv6).
- The first tunneled test was invalidated by a path update and is not counted. Equivalent updates now preserve the measurement; actual route changes still invalidate it.
- A debug-only control repeats the previous dual-stack URL and original timeouts on the same OS route. It does not bypass the VPN.
- Corrected tunneled Wi-Fi and cellular tests await fresh completed reports. No claim of fully verified VPN protection is made.
- Mac current-route endpoint smoke: ipify and ident.me each returned a valid address for both families. This is not a Mac VPN verification.
- The earlier exact ipify error is unknown because the old code discarded its error details.
