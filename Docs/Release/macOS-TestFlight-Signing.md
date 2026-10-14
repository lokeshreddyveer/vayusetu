# macOS TestFlight signing fix

The failed export requested packet-tunnel-provider-systemextension from Mac Team Store profiles that authorize packet-tunnel-provider. This suffix selects Developer ID distribution, not whether the provider is packaged as a system extension.

configure-auto-sign.py now selects the base value for app-store-connect and the suffixed value for Developer ID. Both app and provider retain the system-extension architecture, identifiers and shared Keychain group. Store targets remain sandboxed. The host Store plist also specifies the Utilities category.

The corrected archive exported successfully as dist/testflight/VayuSetu.pkg (0.5.0, build 5). The installer signature and expanded host/provider code signatures, profiles, identifiers, sandbox and network entitlements were verified. The existing Developer ID release validation also passed. archive-testflight.sh now validates the exported payload with verify-testflight.py on future exports.

No upload, Apple server-side validation, TestFlight processing, installation or live tunnel test was performed in this signing fix. The Store host uses the macOS sandbox container; old direct-distribution settings are not automatically migrated. Existing installations were not modified.

Reference: https://developer.apple.com/forums/tags/systemextensions (Apple DTS: Exporting a Developer ID Network Extension).

Organizer archive correction: the unsigned intermediate archive had empty Team and SigningIdentity fields, so Organizer rejected it despite a valid exported PKG. archive-testflight.sh now creates VayuSetu-macOS.xcarchive from the verified Store-signed export. Team and signing identity metadata are derived from the actual distribution signature. Both embedded signatures/profiles are revalidated. Open this final archive in Organizer; VayuSetuVPN.xcarchive remains an intermediate and is not the user upload artifact. Xcode automatic development signing was unavailable because the team had no Mac development-device profiles; no device-registration change was completed.

The final upload archive is build/testflight/VayuSetu-macOS.xcarchive. The intermediate is kept separately in build/testflight/intermediate/VayuSetuVPN.xcarchive. Future builds preserve this separation.

Brand naming: final Mac Store and Developer ID apps use VayuSetu.app and display VayuSetu. Organizer labels use VayuSetu. Internal compilation targets may retain VayuSetuVPN to distinguish the preview target. The two platform bundle IDs require separate App Store Connect records and distinct record names; use VayuSetu for the iOS record and VayuSetu for Mac for the macOS record.


## Upload validation correction — build 6

Apple upload validation rejected build 5 because the system extension Info.plist omitted NSSystemExtensionUsageDescription. The native Swift compilation also omitted debug information, leaving the host and provider without dSYMs.

Build 6 adds the required description to the extension, compiles optimized Swift and C with debugging information, retains Go debugging information, and merges compiler-generated arm64/x86_64 symbols. The archive pipeline includes both dSYM bundles before Store export. verify-symbols.py rejects missing usage text, missing architecture symbols, UUID mismatches, or empty debugging information. verify-testflight.py also rejects a missing extension description.

The build 6 Store export succeeded. Both exported code signatures, provisioning identities, sandbox and Network Extension entitlements passed local verification. Both archived binaries have matching dSYM UUIDs for arm64 and x86_64 with real compilation units and subprogram records. The Organizer Mac archive was replaced after preserving build 5 in Archive-Backups; the iOS archive was not changed. Apple upload validation and TestFlight processing remain pending the user retry. No live tunnel test was performed for this packaging fix.
