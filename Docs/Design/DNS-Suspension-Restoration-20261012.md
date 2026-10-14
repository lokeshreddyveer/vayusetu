# Independent DNS suspension and restoration

Implemented on 2026-10-12 as the next supported integration step.

## Behavior

The confirmed DNS Mode → VPN-Managed DNS transition now suspends the owned independent DNS configuration instead of clearing the user's independent DNS intent. Before removal, the exact installed DoH URL or DoT hostname and bootstrap server list are persisted in Keychain. The current preferred resolver is not substituted during recovery. No raw endpoint/token is written to logs or ordinary preference storage.

Shared reconciliation restores the snapshot only with independent DNS desired, a snapshot present, known OS state, no existing saved configuration, no foreign DNS owner, a ready/stopped VPN and no network operation in progress. Restoration takes the operation guard and verifies exact resolver/bootstrap readback. Attempts are limited to once per minute, with a new explicitly requested VPN transition resetting that bound. iOS may require manual activation after reinstatement. The interface reports that requirement and does not equate configuration restoration with traffic protection.

Explicit System DNS selection, Remove Saved DNS Configuration and emergency-reset DNS removal clear the independent DNS intent and recovery snapshot. Explicit installation of a new resolver supersedes the old snapshot only after successful readback. Safari configuration is untouched.

## Files

- ios/Sources/Secrets.swift: typed Keychain snapshot and pure recovery eligibility policy.
- ios/Sources/PrivacyFeatures.swift: suspension, readback, and exact snapshot restoration.
- ios/Sources/Store.swift: preserved intent on confirmed VPN mode transition, guarded/bounded recovery.
- ios/Sources/DNSViews.swift: accurate confirmation and visible paused preference.
- ios/Tests/RouteTests.swift: nine recovery eligibility checks.
- ios/UITests/LaunchTests.swift: real VPN connection, Home disconnect, configuration restoration and explicit removal regression.

## Validation

All 389 unit checks passed, including 120 routing checks. Final iPhone test suite: 2 tests, zero failures. Result: ios/build/dns-suspension-restoration-final-20261012.xcresult. The first run reached all restoration assertions but failed in test cleanup before the DNS Mode removal button appeared; the final test waits for that refreshed control and passed end to end. macOS Debug unsigned build succeeded; macOS runtime behavior was not tested or installed.

The iPhone regression installed a pending native encrypted DNS configuration, connected the currently selected usable VPN via confirmed VPN-managed mode, observed the preserved suspension notice, disconnected from Home, and observed reinstated DNS configuration awaiting activation. It then explicitly removed that test configuration. Saved resolver/profile credentials remain preserved.

## Limits

This test did not manually activate standalone DNS, test its effective traffic/filtering, exercise both VPN adapters, change to cellular, inject VPN failure, reboot the device or test termination recovery. Snapshot persistence enables later reconciliation, but reboot/relaunch recovery needs independent hardware validation. Do not claim continuous protection or full leak prevention.

Direct Home connection while standalone DNS is active still follows the existing conflict guard. This step implements confirmed mode transitions and restoration, not complete automatic adapter-policy coordination. Local DNS interception and OpenVPN remain unavailable. No TestFlight upload or macOS package replacement was performed.
