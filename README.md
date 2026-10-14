<p align="center"><img src="assets/icon.png" width="112" alt="VayuSetu icon"></p>

<h1 align="center">VayuSetu</h1>
<p align="center"><em>Your network. Your control.</em></p>

<p align="center">
  <a href="../../releases/latest"><b>Download for Mac</b></a> ·
  <a href="https://lokeshreddyveer.github.io/vayusetu/privacy.html">Privacy policy</a> ·
  <a href="https://lokeshreddyveer.github.io/vayusetu/support.html">Support</a>
</p>

VayuSetu is a VPN client, encrypted-DNS app and ad blocker for iPhone and Mac. It does not sell a VPN service and has no servers of its own. You bring the WireGuard or IKEv2 server you already use, pick the encrypted DNS resolver you trust, and VayuSetu ties the two together, filters ads and trackers, and tells you plainly what it has and has not been able to verify.

It has no accounts, no analytics and no tracking. Everything it knows about you stays on your device.

## Screenshots

<p align="center">
  <img src="assets/screenshots/iphone-home.png" width="190" alt="Home: one power button, three protection switches, live speed and activity">
  <img src="assets/screenshots/iphone-settings.png" width="190" alt="Settings">
  <img src="assets/screenshots/iphone-checks.png" width="190" alt="Checks">
  <img src="assets/screenshots/iphone-adblock-test.png" width="190" alt="Adblock test">
</p>
<p align="center"><img src="assets/screenshots/mac-home.png" width="640" alt="VayuSetu on the Mac"></p>

## Download and install

| Platform | Requirements | Status |
|---|---|---|
| **Mac** | macOS 14 or later, Apple Silicon or Intel | [Download the latest DMG](../../releases/latest). Developer ID signed and notarized by Apple. |
| **iPhone** | iOS 17 or later | Coming to the App Store. |

**Installing on the Mac**

1. Open the DMG and drag **VayuSetu** into **Applications**.
2. Open VayuSetu. To run a VPN, macOS asks you to approve the VayuSetu network extension in **System Settings → General → Login Items & Extensions**.
3. To use the ad blockers in Safari, turn them on in **Safari → Settings → Extensions**. There are six, so you can choose which ones to enable.

The download page lists a SHA-256 checksum for the DMG, so you can confirm that the file is intact: `shasum -a 256 VayuSetu-1.0-13-macOS.dmg`.

## What you can do with it

### One power button, three protections

Home has a single power button and three switches that you can combine as you like:

- **VPN** — tunnel your traffic through a WireGuard or IKEv2 server.
- **DNS** — send your lookups to an encrypted resolver, with optional filtering.
- **Adblock** — turn on the Safari content blockers.

You can also pick a ready-made mode: **VPN + DNS**, **VPN only**, **DNS only** (no VPN server required) or **Adblock only**. A switch turns green only when VayuSetu has observed evidence that it is working, not merely because you asked for it.

### Bring your own VPN

- Import a **WireGuard** configuration from a file, the clipboard or a **QR code**, or type the settings in by hand. Export a profile as a QR code to set up another device.
- Add an **IKEv2/IPsec** server using Apple's native adapter.
- Keep several profiles and switch between them. A **backup VPN profile** can be tried automatically, once, if the main one fails to connect.
- Private keys and credentials are stored in the system Keychain.
- OpenVPN is not supported at the moment.

### Encrypted DNS

- **DNS-over-HTTPS** and **DNS-over-TLS**, with the resolver of your choice (for example NextDNS or Control D), or the built-in **VayuSetu DNS**.
- **DNS only mode** runs a small local DNS tunnel on the device, so you get encrypted, filtered DNS without a VPN server.
- A **backup resolver** is asked only when the main one does not answer. It is always encrypted, and VayuSetu never falls back to plain DNS.
- A local cache speeds up repeated lookups, and **CNAME uncloaking** checks the names that a site hides behind, so a tracker cannot slip through by wearing a harmless-looking alias.

### Ad and tracker blocking

- **Six Safari content blockers** — ads, privacy, security, social, annoyances and your own rules — so you can enable only the categories you want.
- **DNS-level blocking** with the same lists, which also covers apps outside Safari that use the system DNS.
- Three filtering levels, **Light**, **Balanced** and **Strict**, plus a catalogue of well-known filter lists you can switch on, your own list URLs, and **custom rules** with allow and block actions.
- A built-in **adblock test** requests real ad, tracker and analytics hosts, with and without your rules, and reports how many were blocked. It keeps a history so you can compare modes.

### Checks that are honest about their limits

The **Checks** screen reads what the system and the tunnel report: whether the tunnel is up, when the last WireGuard handshake happened, whether your DNS lookups are reaching the tunnel, your public IPv4 and IPv6 addresses, DNS resolution through your chosen resolver, and whether a known ad name is actually refused. Each result says what it observed, and the screen states what no app can prove, such as the absence of leaks from other apps. It never calls something "verified" because a setting was accepted. A manual **speed test** and a connection-quality test are included too.

### Privacy Lock and connection rules

- **Strict routing** keeps traffic inside the tunnel and can reconnect automatically with on-demand rules.
- **Trusted Wi-Fi** networks can be exempted from those rules.
- **Emergency reset** removes VayuSetu's VPN and DNS configuration in one step if something goes wrong.

### Made for iPhone

- **Dynamic Island and Lock Screen notifications** announce VPN connected or disconnected, DNS-only connected, and Adblock activated.
- **Widget, Control Center controls and Shortcuts** let you switch protection on and off without opening the app (Control Center controls need iOS 18).
- Haptic feedback on every button and switch, and a dark interface designed around one-handed use.

### Made for Mac

- A native SwiftUI app with a sidebar for Home, VPN Profiles, Encrypted DNS, Adblock and Settings.
- A **menu-bar** control for connecting and disconnecting.
- The WireGuard tunnel runs as a system extension, signed and notarized by Apple.

### Your data

- Encrypted **backup and restore** of your profiles and settings, protected by a password you choose.
- A local, optional connection log and traffic history. You can clear them at any time. Nothing is uploaded.

## Privacy

VayuSetu has no accounts, no analytics and no tracking, and it runs no servers. It contacts only the services that you or a feature you switch on need:

| When | Who it talks to |
|---|---|
| You connect | The VPN server and the DNS resolver you configured |
| Filter lists update | The list sources you enabled |
| You run a public-IP check | An IP-echo service such as ipify or ident.me |
| You run the speed test | Cloudflare's public speed servers (about 70 MB of data) |
| You look up who owns an address (optional, asks first) | RIPEstat |
| You run the adblock test | The ad and tracker hosts it tests, to see whether they are blocked |

Read the full [privacy policy](https://lokeshreddyveer.github.io/vayusetu/privacy.html).

## What VayuSetu cannot do

- It is not a VPN provider. Without a server or profile of your own, only DNS and ad blocking are available.
- A running tunnel and a successful DNS lookup are evidence, not proof. An app that ignores the system DNS settings, or another VPN or filter running at the same time, can bypass any resolver. Checks tells you what it saw and what it can't see.
- iOS lets an app show Dynamic Island notifications only while the app is open, so changes made while VayuSetu is in the background are not announced.
- Safari content blockers work only in Safari. DNS filtering covers other apps that use the system DNS.

## How it is built

VayuSetu is written in Swift and SwiftUI. The iPhone and Mac apps share one set of screens and logic, and each platform has its own packet-tunnel extension. WireGuard runs through the official WireGuard Apple adapter and `wireguard-go`, with a small DNS filter added inside the tunnel. A shared Swift package holds the filter rules, parsers and policy code.

## Source code and license

The source is published here so you can read and review how VayuSetu works. It is **not open source**: it is proprietary, and copying, modifying, redistributing or reusing it is not permitted. See [LICENSE](LICENSE).

| Folder | What is in it |
|---|---|
| `ios/` | The iPhone app, its packet tunnel and Safari extensions, and the Xcode project |
| `macos/` | The Mac app, build and signing scripts |
| `Extensions/` | The Dynamic Island, widget and Control Center extensions |
| `Packages/VayuSetuCore/` | Shared core logic |
| `Docs/` | Architecture, security and design notes |

## Support

Questions, bug reports or feature requests: **contact@lokeshreddy.dev**, or see the [support page](https://lokeshreddyveer.github.io/vayusetu/support.html).

## Credits and legal

VayuSetu includes the WireGuard® Apple adapter and `wireguard-go` under their own licenses, the Public Suffix List, and filter lists published by their respective maintainers; the lists and their licenses are credited inside the app. WireGuard is a registered trademark of Jason A. Donenfeld. Apple, iPhone, Mac, Safari and Dynamic Island are trademarks of Apple Inc.

Copyright © 2026 Lokesh Reddy Veerabhadra. All rights reserved.
