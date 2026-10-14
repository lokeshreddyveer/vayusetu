# Feasibility and release gates

Status: planned; no experiments recorded as passed. Real VPN tests require an authorized provisioned extension, controlled VPN credentials and controlled network destinations. The current Personal Team provisioning error blocks actual iOS tunnel testing.

## Required experiments

| ID | Experiment | Pass evidence |
| --- | --- | --- |
| F01 | Real WireGuard tunnel on selected platform | Handshake plus controlled destination traffic; expected final exit |
| F02 | Native DoH through tunnel | Resolver response/filter positive control and packet-path evidence; no unauthorized fallback |
| F03 | Advanced direct DNS | DNS transport direct, website transport tunneled, arbitrary non-DNS traffic to same resolver IP does not bypass |
| F04 | Bootstrap and resolver-address change | Document bootstrap trust/path, revalidate addresses after path changes; no stale bypass route |
| F05 | IPv4/IPv6 and blocking | Controlled positive/negative tests and physical/tunnel captures; unsupported environments declared |
| F06 | Failure enforcement | Tunnel/resolver outage, process death and transition captures match declared policy |
| F07 | Recovery | Sleep/wake, Wi-Fi/cellular/Ethernet transitions, cancellation and bounded retries |
| F08 | Credentials and exports | Provisioned shared Keychain access; zero secret material in diagnostics/logs/default exports |
| F09 | Installation | Correct signatures/entitlements and clean-device or clean-Mac installation; macOS notarization evidence |

For each run record platform/OS, app and dependency versions, policy, topology, test destination ownership, timestamps, expected result, observations, limitations and artifact locations. Use sanitized configurations. Keep sensitive captures outside public exports.

## Release blockers

Unverified required DNS path; IPv6 bypass; unexpected prohibited fallback; resolver substitution; secret leakage; secure UI verdict without sufficient evidence; inconsistent routes; unprovisioned installation. Build success, adapter counters and one exit-IP response do not clear these gates.

No signed DMG or production-ready claim until the macOS target exists, the release is signed/notarized and installation and networking gates pass. Do not create a DMG containing an unsigned development build and label it a completed VPN release.
