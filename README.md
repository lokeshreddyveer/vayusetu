<p align="center"><img src="assets/icon.png" width="112" alt="VayuSetu icon"></p>

<h1 align="center">VayuSetu</h1>
<p align="center"><em>Your network. Your control.</em></p>

VayuSetu is a VPN, encrypted DNS and Safari ad-blocking app for iPhone and Mac. It connects to the WireGuard or IKEv2 server **you** configure, resolves names through an encrypted resolver you choose, and blocks ads and trackers in Safari and at the DNS level.

It has no accounts, no analytics and no servers of its own.

## Download

| Platform | Status |
|---|---|
| **Mac** (macOS 14 or later, Apple Silicon and Intel) | [Download the latest DMG](../../releases/latest). Developer ID signed and notarized by Apple. |
| **iPhone** (iOS 17 or later) | Coming to the App Store. |

On the Mac, open the DMG, drag VayuSetu to Applications, then approve the VayuSetu network extension when macOS asks (System Settings → General → Login Items & Extensions).

## What it does

- **VPN** — import your own WireGuard profile (file, clipboard or QR code) or add an IKEv2 server. VayuSetu does not sell or provide VPN servers.
- **Encrypted DNS** — DNS-over-HTTPS and DNS-over-TLS, with a built-in filtering resolver or your own (for example NextDNS or Control D). A backup resolver is used only if the main one does not answer, and it is always encrypted.
- **Ad and tracker blocking** — six Safari content blockers (ads, privacy, security, social, annoyances and your own rules) plus DNS-level blocking that includes CNAME-cloaking detection.
- **Checks** — on-device diagnostics for the tunnel, handshake, public IP, DNS and ad blocking. They report what was observed and are clear about what they cannot prove.
- **Your data stays on your device** — profiles, keys and settings are stored locally, with credentials in the system Keychain.

## Privacy and support

- [Privacy policy](https://lokeshreddyveer.github.io/vayusetu/privacy.html)
- [Support](https://lokeshreddyveer.github.io/vayusetu/support.html)
- Contact: contact@lokeshreddy.dev

## Source code and license

The source is published here so you can read and review how VayuSetu works. It is **not open source**: it is proprietary, and copying, modifying, redistributing or reusing it is not permitted. See [LICENSE](LICENSE).

| Folder | What is in it |
|---|---|
| `ios/` | The iPhone app, its packet tunnel and Safari extensions, and the Xcode project |
| `macos/` | The Mac app, build and signing scripts |
| `Extensions/` | The Live Activity, widget and Control Center extensions |
| `Packages/VayuSetuCore/` | Shared core logic |
| `Docs/` | Architecture, security and design notes |

Copyright © 2026 Lokesh Reddy Veerabhadra. All rights reserved. VayuSetu includes WireGuard® components used under their own licenses; WireGuard is a registered trademark of Jason A. Donenfeld.
