# VayuSetu for macOS — 1.0 (build 20 source)

Native SwiftUI app for macOS 14+, with universal Apple Silicon and Intel binaries. Working folder: ~/Documents/VayuSetu/macos.

## Build and automatic signing

```sh
bash scripts/build.sh
bash scripts/build-vpn.sh
python3 scripts/verify.py
bash scripts/release/auto-sign.sh
```

Preview: dist/VayuSetu.app. VPN host with official WireGuard system extension: dist/VayuSetuVPN.app. The direct Developer ID workflow prepares build/devid/VayuSetu.app and dist/release/VayuSetu-1.0-20-macOS.dmg. These paths identify future build 20 output, not a signed or notarized artifact already produced from this source.

The preview does not change VPN settings. The unsigned VPN build disables activation until provisioned. Automatic signing uses the paid team configured in Xcode; validated Developer ID profiles authorize the host and system extension. See ../Docs/Paid-Team-Signing.md. Each new DMG needs its own notarization and stapling.

## App features

Home, VPN Profiles, Encrypted DNS, Diagnostics, Logs, Traffic, History, Routing and Settings; menu-bar connection controls; WireGuard import/edit/duplicate/delete and redacted export; named Keychain-backed HTTPS resolvers with IPv4/IPv6 probes; network and external-IP checks; connection status and live tunnel counters; bounded history; opt-in connection notifications, connect-on-launch and login startup; LAN and app-controlled reconnect settings; sleep/wake evidence invalidation and bounded recovery.

The Mac build shares configuration, persistence, networking policy, diagnostics and lifecycle sources with iOS. Its real packet-tunnel system extension compiles the official WireGuard adapter and pinned Go backend.

## Limits and data

VPN → DNS is the implemented configuration. DNS → VPN remains blocked pending safe DNS-only bypass. On macOS, WireGuard credentials pass to the system extension only during an explicit start. System on-demand starts are disabled; app-controlled reconnect requires VayuSetu to be running, and strict routing is not a persistent kill switch after disconnection. A successful signature, connection status or resolver probe is not verified protection. Live handshake, DNS-path/filter, leak, IPv6 and recovery testing remain outstanding. Custom DNS headers/ports, DoT, DoQ and split DNS are not implemented.

Preview metadata: ~/Library/Application Support/VayuSetu. VPN metadata: ~/Library/Application Support/VayuSetuVPN. Saved credentials remain in the device-local Keychain; a tunnel-start secret is sent in memory to the system extension. Build 20 removes the older plaintext copy from saved VPN preferences when the app loads them. Preview credentials and iPhone data are not transferred automatically. A signed VPN build uses its provisioned shared Keychain group.

Validation includes both architectures, app/extension signatures, WireGuard implementation symbols and release provisioning. UI interactions and live packet paths remain separate verification gates.


Feature expansion: encrypted backups/restores, DoT, custom DNS test domains, HTTPS quality history, live traffic charts, per-profile usage, data alerts, persistent sanitized logs, configurable retry/timeouts and optional native IPv6. Current limitations and verification status: [capability matrix](../Docs/Architecture/Implementation-Gaps.md).
