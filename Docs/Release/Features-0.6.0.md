# Feature expansion: iOS 0.6.0 / macOS 0.3.0

New shared functionality:

- Native DNS-over-TLS tunnel settings and a certificate-validated, cancellable DNS-over-TLS probe with 12-second deadline and bounded framed replies.
- Custom DNS test domains and optional expected-NXDOMAIN diagnostics; A and AAAA selection remains available.
- Password-protected local configuration backups, additive restore and interrupted-restore rollback.
- Real traffic charts, completed-session usage by profile, and configurable combined-transfer alerts.
- Persistent sanitized structured logs with severity, category, timestamp and session correlation; JSON export and deletion.
- Five-request HTTPS quality test, mean/timing variation/failure percentage, family/metered/constrained network details, and 30-check local history.
- Adjustable retry count and connection deadline.
- Optional native-IPv6 requirement validated by the app and privileged extension.
- Product-specific session-history storage.

Credentials remain in Keychain. Backups use AES-256-GCM, PBKDF2-HMAC-SHA256 (600,000 iterations) and random salts. Derivation runs off the UI thread. Restore adds profiles and does not connect or overwrite current selections/security preferences.

Quality checks contact ipify only on request. They report HTTP request timing/failure, never fabricated packet loss. Shared quality reports omit observed IPs. Saved logs omit imported configurations, resolver URLs and raw errors. No analytics are added.

See Architecture/Implementation-Gaps.md for all unimplemented, feasibility-gated and unverified roadmap capabilities. DNS → VPN, per-app routing and multihop are not enabled.
