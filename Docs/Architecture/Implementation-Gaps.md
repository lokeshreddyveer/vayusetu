# VayuSetu capability status

Updated 2026-10-18. Blueprint-1.0.md is the target roadmap; it is not a claim that every future feature is available. The macOS source is 1.0/build 20; build 19 is a separate notarized local DMG and does not contain the build 20 security fixes. Both platforms share profile, credential, connection, diagnostics and backup code.

| Area | Implemented | Still required |
| --- | --- | --- |
| Native products | iPhone tabs/navigation, compact DNS dashboard and editor sheets; macOS sidebar, menu bar, login preference, app icons; hidden scroll indicators | Visual QA of this release on an unlocked iPhone and a clean Mac |
| WireGuard | Official WireGuardKit/Go backend; iOS packet tunnel and macOS system extension | Real provider handshake/exit and transition tests |
| VPN profiles | Multiple providers/profiles; file import, manual create/edit, rename, duplicate, delete, Keychain credentials, redacted export; endpoint editing in configuration | Dedicated multi-candidate endpoint picker, automatic selection, provider adapters/accounts |
| DNS | Multiple named custom resolvers; DoH and DoT; system encrypted DNS settings; TLS hostname validation; A/AAAA probes; custom domain; expected-NXDOMAIN check | Provider-independent filtering evidence, custom authentication headers/ports, cache controls, explicit fallback policy, DNSSEC validation, DoQ and DNS64 |
| VPN → DNS | Native encrypted DNS applied to the WireGuard tunnel; full IPv4/IPv6 routes; no resolver-IP bypass routes | Independent packet-path and application-DNS bypass tests |
| DNS → VPN | Rejected in UI/controller/extension; historical unsupported configurations disabled | DNS-only direct bypass must be proven before enabling; IP route exceptions are insufficient |
| IPv6 | Native full IPv6 when configured; capture/drop fallback when absent; optional native-IPv6 requirement, enforced again inside the extension | Live native-v6/blocking/NAT64 tests; configurable forced-v6-drop mode |
| Routing | Default routes, LAN-access preference, strict-routing preference, exact CIDR conflict validation, setup rollback | Destination/domain split policies, per-app support, policy simulation and independent leak evidence |
| Lifecycle | Explicit unverified/verified states, guards, setup rollback, bounded exponential retries, adjustable 1–10 retry limit and 10–120s timeout, app-active watchdog, path/sleep/wake invalidation | Long-running recovery, cancellation, low-power, network-change and app-update tests |
| Diagnostics | Explicit DNS and public-IP checks; handshake/counters; network families and metered/constrained state; five-request HTTPS quality check; mean and timing variation; bounded 30-check history and sanitized JSON export | Independent DNS/leak/exit-provider evidence, actual packet-loss probes, captive-portal assessment, baseline comparison |
| Traffic | Real sampled rates and counters; 120-point live charts; bounded session history; per-profile completed-session totals; configurable data-threshold alert with opt-in notifications | Background accounting accuracy, monthly budgets, health trends and OS/provider billing reconciliation |
| Logs | Severity/category/session IDs, OSLog, 500-event persistent local ring, 100-event display, text filtering, sanitized JSON export and local deletion | Dedicated severity/category filters, configurable retention and diagnostic bundle integration |
| Secrets and backup | Device-local shared Keychain; macOS build 20 source passes tunnel credentials only during explicit starts and removes the older saved-preferences copy on app load; AES-256-GCM backups; PBKDF2-HMAC-SHA256 at 600,000 iterations; random 32-byte salt; authenticated format/salt; bounded file sizes; additive restore; interrupted-restore rollback journal | Mac upgrade migration and tunnel-start device tests; Keychain failure, interruption and export/import tests; independent security review |
| Automation | iOS on demand; connect on launch, app-active retry, restore selections, macOS login and wake handling; opt-in free-account renewal tooling | macOS unattended WireGuard starts require a secure credential channel; trusted Wi-Fi, per-network selection, scheduled connection policies and configurable security profiles |
| Packaging | Paid-team automatic iOS archive/export; universal Developer ID macOS app/extension signing and DMG; entitlement/profile validation; checksums; build 19 DMG stapled and validated | Build 20 signing and notarization, clean installs/approvals and App Store/TestFlight release gates |
| CI | Local scripts and owner-operated iOS workflow definition | Hosted/self-hosted execution evidence, macOS CI, release approvals and signed update mechanism |
| Future protocols | WireGuard only | OpenVPN, IKEv2 where feasible, provider accounts, DoQ, multihop and additional enterprise management |

## Evidence rules

A successful build or provisioning profile does not prove a VPN path. An OS connected state does not prove DNS transport, resolver identity, leak prevention or filtering. HTTPS timings include TLS/server processing and failed requests are **not packet loss**. NXDOMAIN is consistent with either filtering or a nonexistent name. A/AAAA probes use the app's current route and do not change system DNS.

The previously installed iPhone build was rejected before app launch because Apple's online profile-validation agent reported no network route. This is separate from build/signing validation. The new DNS/UI features still need device interaction testing once the phone has an internet route and is connected/unlocked. The build 19 macOS DMG has a validated stapled ticket; build 20 has not been notarized or tested on a live tunnel.

## Storage and restore

Secrets and backup passwords are never logged. Backup files contain encrypted credentials; the password is not saved. Restores generate new IDs and preserve existing profiles/preferences. A local journal is written before adding Keychain items; a process interrupted before commit restores the original metadata and removes only newly planned credential accounts on next app launch. If recovery fails, configuration edits are blocked and originals/journal are preserved. Journal contents contain old metadata, not plaintext WireGuard configurations or resolver URLs.

Session history now follows the product's storage directory, so signed macOS VPN history is separated from preview history. Historical files are not deleted or migrated automatically. Older sessions without profile IDs remain readable and are excluded from per-profile totals.

## API references

- [Apple native DoT and TLS server name](https://developer.apple.com/documentation/networkextension/nednsovertlssettings/servername)
- [Apple TLS connection options](https://developer.apple.com/documentation/network/nwprotocoltls/options)
- [Apple TLS peer-name validation](https://developer.apple.com/documentation/security/sec_protocol_options_set_tls_server_name(_:_:))
- [Apple CryptoKit authenticated encryption](https://developer.apple.com/documentation/cryptokit/aes/gcm)
