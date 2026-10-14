# Initial threat model

Status: draft. Scope: personal VPN/DNS app and privileged packet-tunnel extension. This is not a completed security audit.

Assets: WireGuard keys, DNS credentials, routing policy, user network traffic, configuration integrity and trustworthy status.
Trust boundaries: imported files → parser; UI → controller; app → Keychain; app → extension; extension → network settings/backend; bootstrap → resolver; diagnostics → external test services; dependency source → signed binaries.

| Threat | Required controls | Evidence still needed |
| --- | --- | --- |
| Malformed or oversized imports | Bounded input, strict fields, safe errors, no shell hooks | Boundary and resource exhaustion tests |
| Secrets in logs or exports | Keychain, redacted exports, structured allowlisted diagnostics | Review all logs, crashes, exports and IPC |
| DNS endpoint substitution | HTTPS validation, TLS verification, explicit endpoint profile identity | Authentication, redirects, trust failures and fallback tests |
| Direct resolver IP bypass | DNS-only transport isolation or unsupported advanced mode | Same-IP arbitrary HTTPS negative control |
| IPv6 and transition leakage | Explicit policy, enforceable routes, verification before secure verdict | Dual-stack, IPv6-only and failure packet captures |
| Concurrent start/stop or stale callbacks | Single controller, operation identity, cancellation | Deterministic transition tests |
| Unsafe rollback / persisted on-demand | Atomic configuration, secret lifecycle, recovery policy | Inject preference, Keychain and extension failures |
| Supply-chain compromise | Pinned source/checksums, licenses, reviewed patches, release signing | Complete platform scans and signed release provenance |
| Misleading green status | Independent verification verdicts | UI and lifecycle tests using failed/inconclusive evidence |

No browsing history or DNS query logging by default. Keep diagnostics bounded and local; sharing must be explicit. Unknown capabilities remain unverified or unsupported, never silently assumed safe.
