<p align="center"><img src="assets/icon.png" width="112" alt="VayuSetu icon"></p>

<h1 align="center">VayuSetu</h1>
<p align="center"><em>Your network. Your control.</em></p>

<p align="center">
  <a href="../../releases/latest"><b>Download for Mac</b></a> ·
  <a href="https://lokeshreddyveer.github.io/vayusetu/">Website</a> ·
  <a href="https://lokeshreddyveer.github.io/vayusetu/privacy.html">Privacy policy</a> ·
  <a href="https://lokeshreddyveer.github.io/vayusetu/support.html">Support</a>
</p>

**VayuSetu is a VPN client, an encrypted-DNS app and an ad blocker for iPhone and Mac, built to tell you the truth about what it is doing.**

It does not sell a VPN service and runs no servers of its own. You bring the WireGuard or IKEv2 server you already use, choose the encrypted DNS resolver you trust, and VayuSetu ties them together, blocks ads and trackers, and reports what it has actually observed instead of what you merely switched on.

- **No accounts, no analytics, no tracking.** Profiles, keys and settings stay on your device, with credentials in the system Keychain.
- **Three protections, one place.** VPN, encrypted DNS and Safari ad blocking can be used alone or combined.
- **Honest status.** A switch turns green only when VayuSetu has seen evidence that the protection works. Checks say what they observed, and what no app can prove.

> **Status.** VayuSetu 1.0 is working software under active development. The Mac build is signed and notarized by Apple; the iPhone app is in App Store review. It has not had an independent security audit, and the tunnel has not yet been validated across every network transition. See [What VayuSetu cannot do](#what-vayusetu-cannot-do).

## Contents

[Download and install](#download-and-install) · [A tour of the app](#a-tour-of-the-app) · [How it works](#how-it-works) · [Privacy](#privacy) · [What VayuSetu cannot do](#what-vayusetu-cannot-do) · [Questions](#questions) · [Source code and license](#source-code-and-license) · [Support](#support) · [Credits](#credits-and-legal)

## Download and install

| Platform | Requirements | Status |
|---|---|---|
| **Mac** | macOS 14 or later, Apple Silicon or Intel | [Download the latest DMG](../../releases/latest). Developer ID signed and notarized by Apple. |
| **iPhone** | iOS 17 or later | In App Store review. |

**Installing on the Mac**

1. Open the DMG and drag **VayuSetu** into **Applications**.
2. Open VayuSetu. To run a VPN, macOS asks you to approve the VayuSetu network extension in **System Settings → General → Login Items & Extensions**.
3. To block ads in Safari, turn the VayuSetu extensions on in **Safari → Settings → Extensions**. There are six, so you can choose which categories to enable.
4. Add a VPN profile, a DNS resolver, or both, then press the power button.

Each release lists a SHA-256 checksum. To check your download: `shasum -a 256 VayuSetu-1.0-14-macOS.dmg`.

**First steps on either platform**

- **DNS and ad blocking only:** choose a resolver (the built-in *VayuSetu DNS* works at once), pick **DNS only** as the mode, and press power. No VPN server is needed.
- **With a VPN:** import your WireGuard file, paste its text, scan its QR code (iPhone) or add an IKEv2 server, then choose **VPN + DNS**.

## A tour of the app

Every picture is a real screenshot of VayuSetu, with its explanation beside it.

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-home.png" width="240" alt="Home"></td>
<td valign="top">

### Home: one button, three protections

The big power button starts and stops protection. Under it are three switches that you can combine freely:

- **VPN** tunnels your traffic through your WireGuard or IKEv2 server.
- **DNS** sends your lookups to an encrypted resolver, with filtering if you want it.
- **Adblock** turns on the Safari content blockers.

Tap the mode name to pick a ready-made combination: **VPN + DNS**, **VPN only**, **DNS only** or **Adblock only**. Below the button are the session timer, live **download and upload speed** and a seven-day chart of the requests VayuSetu's DNS filtering handled and blocked.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-add-profile.png" width="240" alt="Add a profile"></td>
<td valign="top">

### Bring your own VPN

VayuSetu does not sell VPN service. **Add a profile** accepts the server you already have:

- **Import** a WireGuard file, a copied configuration, or scan a **QR code** (iPhone).
- **Set up manually** with WireGuard, or add an **IKEv2/IPsec** server that uses Apple's native adapter.
- Keep several profiles and switch between them. A **backup profile** can be tried once, automatically, if the main one fails to connect.

Private keys and passwords go into the system Keychain. OpenVPN is not supported at the moment.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-confirm.png" width="240" alt="A confirmation sheet"></td>
<td valign="top">

### Clear confirmations

Anything that could interrupt your connection or delete something asks first. The button says exactly what will happen, destructive actions are red, and **Cancel** is always one tap away. On the iPhone it is a slide-up sheet that you can also drag down; on the Mac it is the standard system alert.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-filtering.png" width="240" alt="Filtering settings"></td>
<td valign="top">

### Filtering settings

Choose how aggressive blocking should be: **Light**, **Balanced** or **Strict**. Plain-language switches below turn real blocklists on or off: ads, tracking scripts, fingerprinting, telemetry, scams and ransomware, malicious sites, mining scripts, social buttons and cookie banners. The same rules go to Safari's content blockers and, when DNS is on, to DNS filtering. The status card says whether the rules were really applied.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-catalogue.png" width="240" alt="Filter list catalogue"></td>
<td valign="top">

### A catalogue of filter lists

Add well-known lists with one tap, such as HaGeZi, OISD, AdGuard DNS filter, StevenBlack, Dan Pollock's hosts and EasyList. Each shows its size, what it is for, and whether you have added or enabled it. You can also add your own list by URL, import a file, and write **custom rules** that always allow or block a domain.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-safari.png" width="240" alt="Safari content blockers"></td>
<td valign="top">

### Six Safari content blockers

Safari limits how many rules one extension may hold, so VayuSetu splits blocking across six: **Ads, Privacy, Security, Social, Annoyances and Custom**. For each one this screen shows whether it is on in Safari, how many rules it holds, how much memory they take and when Safari last loaded them. You can rebuild all of them, or reload a single one.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-adblock-test.png" width="240" alt="Adblock test"></td>
<td valign="top">

### Adblock test

Does it really work? The test requests real ad, tracker and analytics hosts twice, once without your rules and once with them, and reports how many were blocked, per category. Change the filtering level, Safari blocking or VayuSetu DNS and test again; **Past tests** lets you compare results over time. A site that is merely down is never counted as blocked.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-checks.png" width="240" alt="Checks"></td>
<td valign="top">

### Checks that are honest about their limits

**Run Available Checks** looks at what is really running: whether the tunnel is healthy, when the last WireGuard handshake happened, your public IPv4 and IPv6 addresses, whether DNS lookups reach the tunnel, resolution through your resolver, and whether a known ad domain is refused. Every row says what was observed, and the screen states what no app can prove, such as the absence of leaks from other apps. A manual **speed test**, a connection-quality test and a traffic view are included.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-privacy-lock.png" width="240" alt="Privacy Lock"></td>
<td valign="top">

### Privacy Lock

**Privacy Lock** keeps your traffic inside the tunnel: strict routing, connect on demand, automatic reconnect and an optional dual-stack WireGuard requirement. **Trusted Wi-Fi** networks can be exempted when Privacy Lock is off. If something goes wrong, **Temporarily Relax Privacy Lock** and **Emergency Reset** are right there. It says plainly that Privacy Lock is not an absolute kill switch, because the system keeps some exceptions of its own.

</td>
</tr>
</table>

<table>
<tr>
<td width="260" valign="top"><img src="assets/screenshots/iphone-settings.png" width="240" alt="Settings"></td>
<td valign="top">

### Settings and notifications

Permissions, protection modes, Privacy Lock, connect on launch and automatic reconnect. On the iPhone, **Dynamic Island notifications** briefly announce VPN connected or disconnected, DNS-only connected, and Adblock activated. The same screen leads to appearance and accessibility, Checks, logs, encrypted backup and restore, and the security centre. The iPhone also has a widget, Control Center controls (iOS 18) and Shortcuts for switching protection without opening the app.

</td>
</tr>
</table>

<table>
<tr>
<td width="420" valign="top"><img src="assets/screenshots/mac-adblock.png" width="400" alt="VayuSetu on the Mac: the Adblock page"></td>
<td valign="top">

### VayuSetu for Mac

The Mac app is designed for the desktop, not stretched from the phone. A sidebar leads to **Home, VPN Profiles, Encrypted DNS, Adblock and Settings**, and each page is a wide two-column layout with panels, tables, menus, hover states and right-click actions. It uses exactly the same engine as the iPhone app: the same profiles, the same DNS filter, the same Checks.

- **Home:** the power button and the three protections on the left; connection, live traffic, DNS activity and status on the right.
- **VPN Profiles:** a list with a details pane, connect, edit, duplicate, export without secrets, and QR export.
- **Menu bar:** switches for VPN, Encrypted DNS and Adblock, and a power item.
- **Keyboard:** ⇧⌘P turns protection on or off, ⇧⌘M opens the mode chooser.
- **System extension:** the WireGuard tunnel runs as a macOS system extension, signed and notarized by Apple.

The screenshot shows the Adblock page before Safari protection is switched on.

</td>
</tr>
</table>

## How it works

- **One engine, two apps.** The iPhone and Mac apps share the same logic: the store, the tunnel controller, the profile and DNS code, the filter engine and the Checks. Each platform has its own screens, and its own packet-tunnel extension built from the same tunnel code.
- **VPN.** WireGuard runs through the official WireGuard Apple adapter and `wireguard-go`. IKEv2 uses Apple's native adapter.
- **Encrypted DNS.** A small DNS runtime inside the tunnel answers lookups. It speaks DNS-over-HTTPS or DNS-over-TLS to the upstream resolver, keeps a short cache, checks CNAME chains so a tracker cannot hide behind a harmless-looking alias, and can fall back to a second encrypted resolver. DNS-only mode runs this runtime on its own, with no VPN server.
- **Filtering.** The enabled lists compile into a compact snapshot that the tunnel reads. Rules are allow or block, for a domain and its subdomains or for one exact name. An allow rule always beats a block rule, so Website Exceptions can switch filtering off for a whole site. The contract is written down in [DNS rule precedence](Docs/Architecture/DNS-Rule-Precedence.md) and pinned by tests.
- **Safari.** The same lists feed six Safari content-blocker extensions, split by category to stay within Safari's rule limits.
- **Evidence, not assumptions.** Protection states come from what the system and the tunnel report: the tunnel's status, the last handshake, counters that are still fresh, answered lookups, a lookup of a known-blocked name. Stale numbers are not evidence.

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

Credentials live in the Keychain. Connection logs and traffic history are optional, stay on the device, and can be cleared at any time. Backups are encrypted with a password you choose. Read the full [privacy policy](https://lokeshreddyveer.github.io/vayusetu/privacy.html).

## What VayuSetu cannot do

- **It is not a VPN provider.** Without a server or profile of your own, only DNS and ad blocking are available.
- **A running tunnel is evidence, not proof.** An app that ignores the system DNS settings, or another VPN or filter running at the same time, can bypass any resolver. Checks tells you what it saw and what it can't see.
- **Privacy Lock is not an absolute kill switch.** Apple keeps some exceptions of its own.
- **"Resolve outside the VPN" is a trade-off.** If you switch it on, the connection to your resolver leaves the VPN; your network can see which resolver you use, though not the lookups. VayuSetu shows a warning when it is on.
- **Safari content blockers work only in Safari.** DNS filtering covers other apps that use the system DNS.
- **Dynamic Island notifications** can appear only while the iPhone app is open, because iOS allows nothing else.
- **OpenVPN** is not supported. **Certificate-based IKEv2** is not yet available on the Mac. The Mac app has no QR-code scanner, widgets or Shortcuts.
- **Not independently audited.** The code is published for review, but VayuSetu has not had a third-party security audit, and the tunnel has not yet been validated against every network transition.

## Questions

**Do I need a VPN subscription?** Only if you want the VPN part. DNS-only mode and ad blocking work on their own.

**Does VayuSetu see my browsing?** No. It has no servers. DNS lookups go from your device to the resolver you chose, and the filter runs on your device.

**Why does the status say "not verified"?** Because VayuSetu will not say a protection works until it has seen evidence. Run the checks, or use the connection for a moment, and it updates.

**Will blocking break websites?** Sometimes, especially in Strict mode. Use **Website Exceptions** to turn blocking off for one site.

**Can I move my profiles to another device?** Yes: show a profile's QR code, or make an encrypted backup and restore it.

## Source code and license

The source is published here so you can read and review how VayuSetu works. It is **not open source**: it is proprietary, and copying, modifying, redistributing or reusing it is not permitted. See [LICENSE](LICENSE).

| Folder | What is in it |
|---|---|
| `ios/` | The iPhone app and its shared logic, packet tunnel, Safari extensions, tests and the Xcode project |
| `macos/` | The Mac app's screens, build and signing scripts |
| `Extensions/` | The Dynamic Island, widget and Control Center extensions |
| `Packages/VayuSetuCore/` | Core logic shared by both apps |
| `Docs/` | Architecture, security and design notes, including [DNS rule precedence](Docs/Architecture/DNS-Rule-Precedence.md) |

## Support

Questions, bug reports or feature requests: **contact@lokeshreddy.dev**, or see the [support page](https://lokeshreddyveer.github.io/vayusetu/support.html).

## Credits and legal

VayuSetu includes the WireGuard® Apple adapter and `wireguard-go` under their own licenses, the Public Suffix List, and filter lists published by their respective maintainers; the lists and their licenses are credited inside the app. WireGuard is a registered trademark of Jason A. Donenfeld. Apple, iPhone, Mac, Safari and Dynamic Island are trademarks of Apple Inc.

Copyright © 2026 Lokesh Reddy Veerabhadra. All rights reserved.
