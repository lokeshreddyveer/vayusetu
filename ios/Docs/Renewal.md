# iPhone preview renewal

The scheduler is disabled by default. Applies only to the free-signing **VayuSetu** preview, not the Network Extension VPN scheme.

## Renew now

```sh
cd ~/Documents/VayuSetu/ios
bash scripts/renew-ios.sh renew
```

Rebuilds from current source, signs with your existing Xcode Personal Team, verifies the app/signature/profile and installs over the same bundle ID. It does not uninstall or erase app data. It does not launch the app or interrupt a foreground activity by opening it. Pair/trust the phone, enable Developer Mode, connect it by USB or available Xcode wireless pairing, unlock it, and sign into Xcode first. Xcode may request account authentication or Keychain access; unattended success is not guaranteed.

## Optional scheduling

```sh
bash scripts/renew-ios.sh preview-schedule  # inspect without enabling
bash scripts/renew-ios.sh enable            # opt in
bash scripts/renew-ios.sh status
bash scripts/renew-ios.sh disable           # stop and remove scheduler
```

Enable installs a per-user LaunchAgent at ~/Library/LaunchAgents/app.vayusetu.ios.renewal.plist. It checks hourly while this Mac is awake and you are logged in, including once at load. Attempts renewal when the recorded installed profile has 48 hours or less remaining (or no installation is recorded), at most once per four hours. A missed/disconnected attempt is retried later; it cannot renew while the Mac is asleep/offline or the phone is unavailable. It never stores an Apple password or bypasses Apple signing restrictions. Disabling an in-progress job may stop that attempt; the existing phone app is retained.

Defaults target your paired iPhone UDID and current Personal Team. Override with --device HARDWARE_UDID --team TEAM_ID on renew or enable if they change.

## Expiration and failures

Apple Personal Team profiles expire seven days after **issuance**, not seven days after installation: https://developer.apple.com/support/compare-memberships/

Xcode automatic signing may reuse a valid profile. The script records the actual expiration from the newly built embedded profile and explicitly reports reuse or near-expiry signing; a reinstall alone does not extend that date. No unrelated cached profiles are deleted or certificates revoked. If Xcode cannot issue a usable profile, open Signing & Capabilities in Xcode and resolve its account/signing error.

Status and per-attempt build/install logs live under ios/build/renewal/. A failed build or install preserves the last successful installation expiry and records the failure separately. The scheduler logs errors locally; it does not send notifications. Keep this project at its current path while scheduling is enabled.

## Verification

2026-10-10: real clean build, signing checks and installation succeeded on the paired iPhone. Embedded profile expiration: 2026-10-17 18:25:46 CDT. Four regression tests passed for expiry-based scheduling and preserving installed-state evidence on build, profile or install failure. Generated LaunchAgent passes plist validation. Scheduling has not been enabled or tested as an active background job.
