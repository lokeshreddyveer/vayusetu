# VPN + DNS: no traffic after "Connected" — test plan

Status: **not yet run.** Written before any new build. Covers two unexplained results from the build 58 security run (20:45, 25 Oct):

1. VPN + DNS reported Connected, but one `curl -4 https://api64.ipify.org` ten seconds later returned nothing (8 s limit).
2. With the app quit while VPN + DNS was on, the same single probe returned nothing three seconds after the quit.

In both runs the same moments showed 12 of 12 name lookups answered, no DNS leak, and an ad domain blocked. VPN-only and DNS-only passed the same probe. The tunnel log showed no error. So the evidence does not yet separate a **weak probe** from a **real stall**.

## Hypotheses

| | Hypothesis | Predicts |
|---|---|---|
| H1 | The probe was too strict: one attempt, hostname lookup included, 8 s, ten seconds after connect. | Retried probes succeed within seconds; IP-literal and hostname probes both work. |
| H2 | The first lookups through the DNS tunnel are slow while its upstream (encrypted, carried by the VPN) warms up. | Hostname probe slow or failing early; IP-literal probe works at once; lookup time falls over the first minute. |
| H3 | The data path stalls only in VPN + DNS (for example large packets lost because of the tunnel's MTU, or the DNS tunnel wrapping the interface). | IP-literal small probes work; large packets or TLS handshakes fail; failure persists past a minute and does not appear in VPN-only. |
| H4 | Quitting the app disturbs the path (a network flap or the tunnel losing something the app supplies). | Probes right after the quit fail and recover on their own or after reopening; the control run (same timings, app left open) is clean. |

## Instrumentation (all read-only on the tunnel; nothing is changed except the protection switches)

Per probe, timestamped: egress address; time for name lookup, connect, total; interface and first resolver; the tunnel interface's byte counters (`netstat -ib` on the utun) before and after.

Discriminating probes, run together at each step:
- **P-host**: `curl -4` to a hostname (lookup + connect + TLS).
- **P-literal**: `curl -4 --resolve` pinned to the address learned in the baseline, so no lookup is involved.
- **P-tcp**: plain TCP connect to a fixed public address on 443 (no TLS).
- **P-dns**: a lookup through the local DNS address, timed, repeated for a name not seen before.
- **P-big**: ping with a payload near the tunnel MTU (`ping -D -s 1372 -c 3`) to a public address, then a smaller one, to find where loss starts.
- **P-udp-dns-only control**: the same P-dns with only DNS on, to compare.

Logs to capture for each run: the app's connection events, the tunnel's log (start-up stages and bootstrap messages), `scutil --nc status`, the route and DNS configuration at each step.

## Procedure

Always start and end with protection off; restore with `both/off`, `vpn/off`, `dns/off` and verify. Stop at once on: a system-extension prompt, a Connected tunnel with no traffic for 30 s (restore first), the app quitting unexpectedly, or protection that cannot be restored.

1. **Control A — VPN only**, 60 s of the full probe set at 1, 2, 4, 8, 16, 32, 60 s after Connected.
2. **Test B — VPN + DNS**, same schedule. Compare P-host / P-literal / P-tcp / P-dns / P-big with A.
3. **Control C — VPN + DNS, app left open**, same schedule again (second connect, to separate "first connect" from "VPN + DNS").
4. **Test D — VPN + DNS, then quit the app**, probes at 1, 2, 4, 8, 16, 32 s after the quit; then reopen and probe again.
5. **Control E — VPN + DNS, app left open for the same duration as D**, probes at the same offsets.
6. Restore and verify.

## Reading the results

| Observation | Conclusion | Next step |
|---|---|---|
| All probes succeed in B and C within a few seconds; the original single probe would have failed | H1: weak probe | Replace the single probe in `verify-security.sh` with the retried set; close item 1. |
| P-literal and P-tcp succeed at once, P-host / P-dns slow or failing early, improving with time | H2: DNS warm-up | Measure how long; decide whether the app should wait for the first successful lookup before reporting protected. |
| P-literal and P-big fail in B and C but not A | H3: data path | Examine MTU and the DNS tunnel's packet handling; do not release. |
| D fails and E is clean | H4: the quit disturbs the path | Trace what the app supplies the tunnel; do not release. |
| D and E both fail the same way | The cause is VPN + DNS, not the quit | Handle under H2 or H3. |
| Everything passes in all steps | Not reproduced | Record that; keep NO-GO until it has passed on two separate runs. |

## Prerequisites

A candidate build that passes `verify-release.sh`, is notarized (an unnotarized build cannot replace an installed extension), and is installed with the previous build kept as a fallback. This plan is run **after** the focused review of the extension-install failure reporting.
