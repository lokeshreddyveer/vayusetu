# DNS provider and independent website verification

Implemented for both native apps, iOS 0.11.1 (17) and macOS 0.6.1 (9).

## Where to find it

DNS → DNS Diagnostics → DNS Provider & Website Checks. Also available from connection Verification → DNS evidence.

Check All DNS Providers runs on demand, selected provider first, on the app's current system route. It does not send the saved resolver URL/token to test services, configure a replacement resolver, change VPN policy, or bypass the tunnel. Results are invalidated on network, VPN-state or resolver changes. Run checks again after transitions.

| Provider | Native method | Interpretation |
|---|---|---|
| Control D | System resolution of published `verify.controld.com` verification name | Published answer supports Control D in this sampled path. Missing answer is inconclusive, per provider guidance. |
| NextDNS | Official `test.nextdns.io` request, then validated provider-only randomized-host handshake | `ok` supports NextDNS. `unconfigured` and unknown schemas stay inconclusive. No arbitrary JavaScript is executed by the native adapter. |
| AdGuard | Randomized `-dnscheck.adguard-dns.com/dnscheck/test` endpoint from the official website's current DNS-check implementation | Recognized service/transport fields support AdGuard for this sample. Missing/unknown fields or failed resolution stay inconclusive. Private server/device identifiers are discarded. |
| Quad9 | Official DNS-sensitive `on.quad9.net` page | Only recognized YES/NO headings are classified. Changed markup stays inconclusive. |
| Cloudflare | Official `one.one.one.one/help` in embedded WebKit | Browser-driven verification is required. No unvalidated native API or hosting/IP heuristic is represented as a pass. |

All five official websites can be opened inside the app. BrowserLeaks and DNSLeakTest are included as separate independent checks. They execute their real website tests in nonpersistent WebKit, with ordinary OS routing/TLS and no injected DNS/proxy settings. Results remain visible as website results; app navigation/loading does not imply a passed DNS test. Top-level navigation is restricted to the chosen service, and certificate validation is never overridden. Websites receive connection metadata when opened; loading occurs only after the user's navigation.

BrowserLeaks uses randomized IPv4-only and IPv6-only hostnames to observe recursive resolvers. DNSLeakTest offers independent randomized-domain tests. Those samples describe the embedded browser's DNS path. They are not DNS-only ad-blocking scores or device-wide leak-isolation proofs. Provider upstream hosting/ASN names can differ from the selected brand. Multiple provider detections or disagreement with the selection warrant investigation; neither missing evidence nor a page failure is automatic proof of a leak.

## Investigating the existing ipify failure

The recent real-iPhone report showed the configured resolver returning blocking responses for both ipify hostnames; the independent IPv4 endpoint still worked. That supports DNS filtering of the diagnostic domains rather than total tunnel failure. Retain the working address-discovery fallback and inspect the selected provider's policy. Do not weaken routing or automatically switch DNS to make a diagnostic green. If the user intends to allow ipify, review an explicit provider-side domain allow rule separately.

For suspected unexpected DNS, keep the VPN connected, run native checks, then compare BrowserLeaks and DNSLeakTest. Review applied tunnel DNS configuration, DNS-only conflicts, cached answers, upstream forwarding and Private Relay before drawing conclusions. Reconnection/failure isolation requires additional controlled testing.

## Verification and limits

- 295 regression assertions passed, including 20 added provider parser/handoff/redaction cases.
- iOS Debug build and signed Release archive passed; embedded host/tunnel/Safari/Live Activity signatures and capabilities verified.
- Live native adapter tests were performed on the Mac's current route. These were not an iPhone or VPN-isolation test: Control D inconclusive, NextDNS unconfigured/inconclusive, AdGuard lookup unavailable/inconclusive, Quad9 negative, Cloudflare website required.
- macOS universal build, Developer ID signing and DMG notarization passed; Apple accepted the notarization and its ticket was stapled and validated.
- Physical-iPhone installation and the embedded-browser UI test are pending phone availability. No current iPhone provider-identity pass is claimed.
- Remote website schemas can change. Unknown results fail conservatively and remain inconclusive.
- Native responses use ephemeral sessions, 8-second request and 10-second resource limits, 128 KB maximum bodies, no HTTP redirects, no stored cookies/credentials, and sanitized exported reports. NextDNS permits only its validated random test subdomain. Full response bodies, public IPs and account IDs are never exported.

## Primary sources

- [Control D verification guidance](https://docs.controld.com/docs/check-if-dns-is-working)
- [NextDNS official test](https://test.nextdns.io/) and [official diagnostic implementation](https://github.com/nextdns/diag)
- [AdGuard official test and its DNS-check script](https://adguard.com/en/test.html)
- [Cloudflare verification guidance](https://developers.cloudflare.com/1.1.1.1/faq/)
- [Quad9 verification guidance](https://docs.quad9.net/FAQs/)
- [BrowserLeaks DNS test method](https://browserleaks.com/dns)
- [DNSLeakTest explanation](https://www.dnsleaktest.com/what-is-a-dns-leak.html)
