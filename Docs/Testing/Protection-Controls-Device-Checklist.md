# Protection controls: real-device checklist

Status: written 2026-10-13 for build iOS 0.11.2 (18) plus the coordinator work in ADR-011. Nothing below has been run
on a device yet unless a result is filled in. Host tests (planner, DNS codec, rule snapshot, Go filter) prove logic only.

How to read results: record **requested** state (what you tapped) and **observed** state (pill colour, DNS counters,
Settings → VPN). A pill is green only on observed evidence.

## Setup
- Paired iPhone, unlocked, signed VPN build installed (scheme VayuSetuVPN).
- At least one WireGuard profile, optionally one IKEv2 profile, and the built-in VayuSetu DNS (or your own resolver) selected.
- Pull the app's own log after a run: `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer
  --domain-identifier app.vayusetu.ios --source "Library/Application Support/VayuSetu/connection-events.json" --destination events.json`.
- Tunnel start-up breadcrumbs: launch once with `--startup-check`, then copy `last-startup-diagnostic.txt` the same way.

## The eight combinations (VPN / DNS / Safari)
| # | Set up | Expected observed result | Result |
| --- | --- | --- | --- |
| 1 | All pills off | Power gray, "Choose a mode or tap power to connect." | |
| 2 | DNS only | Teal power; DNS pill amber, then green after the counter shows answered queries; Settings → VPN shows the VayuSetu tunnel; VPN pill off | |
| 3 | VPN only (WireGuard) | Blue power; VPN pill green; DNS pill off; DNS follows the profile's `DNS =` line | |
| 4 | VPN + DNS (WireGuard, VayuSetu DNS) | Green power; both pills; "Blocked by VayuSetu lists" rises on an ad-heavy page | |
| 5 | Safari only | Power gray; Adblock pill amber until Safari's own switch is on, then green | |
| 6 | DNS + Safari | As 2, Adblock independent | |
| 7 | VPN + Safari | As 3, Adblock independent | |
| 8 | VPN + DNS + Safari | As 4, Adblock independent | |

## Transitions (record the visible gap and the final observed state)
1. VPN + DNS → VPN pill off → becomes DNS Only; brief interruption is reported.
2. VPN + DNS → DNS pill off → remote VPN stays connected; WireGuard reconnects once to drop the filter; profile DNS restored.
3. VPN Only → DNS pill on → reconnect, DNS pill green only after answered queries.
4. DNS Only → VPN pill on → tunnel handoff, VPN green, DNS evidence returns.
5. DNS Only / VPN Only / VPN + DNS → power → everything network-side stops; Safari unchanged.
6. Safari on/off never starts or stops a tunnel.
7. Rapid repeated taps on each pill and the power button: no stuck "starting", no double connects in the log.
8. Mode sheet while off: choosing a mode only saves it. While on: "Switch Now" / "Use Next Time".

## IKEv2
- Connect IKEv2: DNS pill shows limited (amber), never green; the DNS tab shows the "IKEv2 and DNS" card.
- Turn the VPN pill off with DNS on: IKEv2 stops, DNS Only starts.
- Switching DNS protection to IKEv2 asks before downgrading.
- Confirm what DNS the session really uses with the Checks screen; the app does not claim your chosen resolver is applied.

## Failures and recovery
- Failed remote VPN start (bad profile): red pill, message, previous state restored.
- Failed DNS-only start: log shows "VPN start request was not acted on by iOS" retries, then a clear message.
- Resolver timeout: queries return failure, never plaintext fallback; counter "Upstream failures" rises.
- Wi-Fi ↔ cellular, sleep/wake, background for 10 minutes, force-quit and relaunch, reboot: status is re-derived from the OS, not from saved choices.
- Safari extension disabled in Settings: Adblock pill stays amber and the notice says where to enable it.

## Known unproven items
- WireGuard filter sending its upstream queries inside the VPN (the "Resolve outside the VPN" switch is the fallback).
- DNS-only tunnel on IPv6-only/NAT64 networks, TCP DNS, replies larger than the tunnel MTU.
- Behaviour after reboot with the VPN configuration present.
- OpenVPN: not implemented (licensing decision pending); IKEv2 local filtering: impossible by platform design.
