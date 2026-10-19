# Paid-team signing

Team: X4MH29QNRS. Project and output files stay in ~/Documents/VayuSetu.

## iPhone

Use the VayuSetuVPN scheme in ios/VayuSetu.xcodeproj. Automatic signing provisions both the host and VayuSetuTunnel. The preview scheme is a separate app and does not automatically transfer its profiles or credentials.

Local signed IPA:

```sh
cd ~/Documents/VayuSetu/ios
VAYU_DEVELOPMENT_TEAM=X4MH29QNRS bash scripts/release/archive-ios.sh
```

Output: ios/dist/release/VayuSetuVPN.ipa. No upload is performed. The build script checks both signatures, provisioning, VPN entitlements and shared Keychain access. The exported IPA has also been unpacked and checked.

The paid development build was installed on the paired iPhone and Home was visually verified after launch. Its app and tunnel development profiles expire on October 11, 2027 UTC. This is no longer a seven-day Personal Team build. A working tunnel still requires an imported WireGuard configuration and saved HTTPS resolver; real handshake, filtering and leak checks remain outstanding.

## Mac

```sh
cd ~/Documents/VayuSetu/macos
bash scripts/build.sh
bash scripts/build-vpn.sh
bash scripts/release/auto-sign.sh
```

The signing workflow generates VayuSetuSigning.xcodeproj around the existing universal binaries. It preserves restricted entitlements in the archive, then uses Xcode's automatic Developer ID distribution export to request the exact host and system-extension profiles. Profiles are validated before preparing the final signed app and DMG. Xcode must have the developer account signed in, and the local Developer ID Application certificate must have its private key.

The automatic signing command above names its output from the bundle version and build, for example `macos/dist/release/VayuSetu-1.0-20-auto-signed-macOS.dmg` for build 20. The separate direct Developer ID workflow (`scripts/release/sign-devid.sh`) includes the network filter and writes `macos/dist/release/VayuSetu-1.0-20-macOS.dmg`. The host and system extension require matching Developer ID signatures and validated profiles. Preview and VPN metadata are separate; credentials from the preview are not transferred automatically.

Signing is separate from notarization. A newly built DMG is not a notarized public release until Apple's notarization result is Accepted and the ticket is stapled and validated. With a configured Keychain notary profile, pass the exact signed DMG to `scripts/release/notarize.sh`, for example `bash scripts/release/notarize.sh dist/release/VayuSetu-1.0-20-macOS.dmg`. It performs an explicit submission to Apple. No public App Store or TestFlight publication is part of this workflow.

Installing and activating the Mac extension requires an app in Applications and macOS approval. Signing alone is not evidence of a successful tunnel or leak prevention.
