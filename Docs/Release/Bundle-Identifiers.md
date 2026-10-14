# VayuSetu bundle identifiers

Current application identity after the October 11, 2026 rename:

| Target | Bundle identifier |
|---|---|
| iOS VPN app | app.vayusetu.ios |
| iOS packet tunnel | app.vayusetu.ios.tunnel |
| macOS VPN app | app.vayusetu.macos |
| macOS system extension | app.vayusetu.macos.tunnel |
| iOS preview app | app.vayusetu.ios.preview |
| macOS preview app | app.vayusetu.macos.preview |

The preview targets intentionally have separate identifiers from the VPN targets.
Shared Keychain groups are TEAM.app.vayusetu.ios.shared and TEAM.app.vayusetu.macos.shared. The developer team is X4MH29QNRS. Extension provider IDs, macOS Mach service names, signing validation and provisioning scripts use the new identifiers.

Create App Store Connect records using app.vayusetu.ios and app.vayusetu.macos. Do not create app records for either tunnel extension or preview target. The visible product name remains VayuSetu.

These are new application identities, not an update to an installation using the previous identifiers. Existing installations, VPN configurations and Keychain items have not been deleted or migrated. Export configuration from the old app before switching identities and reimport as needed. The optional renewal LaunchAgent now uses app.vayusetu.ios.renewal; this change does not install or enable a scheduler, nor alter an already installed old scheduler.

Historical build reports and previous release artifacts may retain their original identifiers. Rebuilt archives must be checked before upload; do not upload a previous archive under the new app record.

Validation after rebuilding:
- All 171 automated checks passed.
- iOS 0.8.0 (12) archived, signed and exported for App Store Connect. Both host and extension IDs in the exported IPA were verified, and its ZIP integrity passed.
- macOS 0.5.0 (5) universal host and system extension built. Developer ID profiles, exact identifiers and signatures validated; the signed DMG checksum passed.
- macOS App Store Connect export now succeeds after selecting packet-tunnel-provider for Store distribution and retaining packet-tunnel-provider-systemextension for Developer ID. The exported installer signature, both embedded code signatures, app identities, sandbox entitlements and Apple profiles were verified. Upload and Apple processing are still pending.
- No new-identity build was installed on hardware or uploaded in this rename step. Existing installations were preserved.
