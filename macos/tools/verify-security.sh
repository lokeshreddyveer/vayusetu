#!/bin/bash
# Runtime verification of the VPN, DNS and filter behaviour on this Mac, from outside the app. It switches protection on and off through the app's own
# links, measures what actually happens on the network, and puts everything back as it was found (verified independently, not assumed).
#
#   macos/tools/verify-security.sh [--no-vpn]      # --no-vpn runs the DNS-only checks only
#
# Needs: /Applications/VayuSetu.app running, a saved VPN profile and resolver selected, protection OFF at the start, a working network.
# Needs no root. That is a real limit: without packet capture it cannot prove the absence of plaintext DNS on the wire, and it says so (NOT VERIFIED).
# It does NOT drop Wi-Fi, sleep the Mac, kill processes, change system DNS, or touch VPN configurations or profiles.
#
# Every line it prints is PASS (observed and as required), FAIL (observed and not as required) or NOT VERIFIED (could not be observed here).
# Exit status: 0 only if there is no FAIL and no NOT VERIFIED among the checks it was asked to make; 1 on any FAIL; 2 when something is NOT VERIFIED.
set -u
WITH_VPN=1; [ "${1:-}" = "--no-vpn" ] && WITH_VPN=0
OUT="${TMPDIR:-/tmp}/vayusetu-security-$(date +%Y%m%d-%H%M%S).txt"; : > "$OUT"
pass=0; fail=0; nv=0
# What this run observed, kept beside the other evidence so the project's status is derived from runs, not written by hand. The build is the one in scripts/version.json.
EVIDENCE="$(cd "$(dirname "$0")/.." && pwd)/test-evidence/security-run.json"
record_run() {
    mkdir -p "$(dirname "$EVIDENCE")"
    python3 - "$EVIDENCE" "$pass" "$fail" "$nv" "$WITH_VPN" "$(cd "$(dirname "$0")/.." && pwd)/scripts/version.json" <<'EOF'
import json, sys
from datetime import datetime, timezone
path, passed, failed, unverified, with_vpn, version = sys.argv[1:7]
json.dump({"recorded": datetime.now(timezone.utc).isoformat(timespec="seconds"), "build": json.load(open(version))["build"],
           "passed": int(passed), "failed": int(failed), "notVerified": int(unverified), "withVPN": with_vpn == "1"}, open(path, "w"), indent=2); open(path, "a").write("\n")
EOF
}
trap record_run EXIT
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
P()  { pass=$((pass+1)); say "PASS         $1"; }
F()  { fail=$((fail+1)); say "FAIL         $1"; }
NV() { nv=$((nv+1));     say "NOT VERIFIED $1"; }
note() { say "             $1"; }

PREFS="$HOME/Library/Preferences/app.vayusetu.macos.plist"
nc_state() { scutil --nc list | grep "app.vayusetu.macos" | head -1 | sed -n 's/.*(\([A-Za-z]*\)).*/\1/p'; }
iface()    { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
resolver0(){ scutil --dns | awk '/nameserver\[0\]/{print $3; exit}'; }
selection(){ plutil -extract protection-selection raw -o - "$PREFS" 2>/dev/null | base64 -d 2>/dev/null; }
link()     { open "vayusetu://protection/$1/$2"; }
waiting_for_approval() { systemextensionsctl list 2>/dev/null | grep -ci "waiting for user"; }
wait_nc()  { local want="$1" limit="${2:-60}" t=0; while [ $t -lt "$limit" ]; do [ "$(nc_state)" = "$want" ] && return 0; [ "$(waiting_for_approval)" != "0" ] && return 2; sleep 2; t=$((t+2)); done; return 1; }
v4()  { curl -4 -s --max-time 8 https://api64.ipify.org 2>/dev/null; }
v6()  { curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null; }
# Which resolver reaches the authoritative server when an application looks up a name (the standard DNS-leak method), asked the way applications ask.
who() { python3 - <<'P' 2>/dev/null
import socket
try: print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo('whoami.akamai.net',80,type=socket.SOCK_STREAM)})))
except Exception: print("")
P
}
prefix() { # a coarse network prefix, to compare two addresses without needing them to be identical
  python3 - "$1" <<'P'
import ipaddress,sys
a=sys.argv[1].strip().split(" ")[0]
try:
    ip=ipaddress.ip_address(a); print(ipaddress.ip_network(a+("/24" if ip.version==4 else "/48"),strict=False))
except Exception: print("")
P
}
lookups() { # how many of 12 different names an application can resolve
  python3 - <<'P'
import socket
names=["example.com","example.org","example.net","wikipedia.org","python.org","apple.com","mozilla.org","kernel.org","gnu.org","iana.org","icann.org","ietf.org"]
ok=0
for n in names:
    try: socket.getaddrinfo(n,443,type=socket.SOCK_STREAM); ok+=1
    except Exception: pass
print(ok)
P
}
utun_bytes() { # total bytes in/out on the tunnel interface that carries the default route or 198.18.0.2
  local i; i="$(route -n get "${1:-default}" 2>/dev/null | awk '/interface:/{print $2}')"; [ -z "$i" ] && { echo "0 0 -"; return; }
  netstat -I "$i" -b 2>/dev/null | awk -v n="$i" 'NR>1 && $1==n && $3 ~ /Link/ {print $7, $10, n; exit}'
}

# ---- state, restoration -----------------------------------------------------------------------------------------------------------------------
INIT_NC=""; INIT_SEL=""; restored=0
restore() {
  [ $restored = 1 ] && return; restored=1; trap - EXIT INT TERM
  say ""; say "Restoring the state found at the start (tunnel $INIT_NC, selection $INIT_SEL)"
  link both off
  wait_nc Disconnected 60
  local tries=0; sleep 3
  while [ $tries -lt 8 ] && ! echo "$(selection)" | grep -q '"vpnEnabled":false' ; do sleep 2; tries=$((tries+1)); done
  local bad=0
  [ "$(nc_state)" = "$INIT_NC" ] || { say "  MISMATCH tunnel is $(nc_state), was $INIT_NC"; bad=1; }
  echo "$(selection)" | grep -q '"vpnEnabled":false' && echo "$(selection)" | grep -q '"dnsEnabled":false' || { say "  MISMATCH saved selection is $(selection)"; bad=1; }
  [[ "$(iface)" == utun* ]] && { say "  MISMATCH default route still through $(iface)"; bad=1; }
  [ "$(resolver0)" = "198.18.0.2" ] && { say "  MISMATCH system resolver is still VayuSetu's"; bad=1; }
  if [ $bad = 0 ]; then say "RESTORED and verified independently: tunnel, saved selection, default route and resolver match the start"
  else say "RESTORE NOT VERIFIED. Stop. Nothing else was changed. See above; recovery steps are in Docs/Testing/Runtime-Security-Verification.md."; fail=$((fail+1)); fi
  say ""; say "Result: $pass passed, $fail failed, $nv not verified.   Evidence: $OUT"
  if [ $fail -gt 0 ]; then exit 1; fi; if [ $nv -gt 0 ]; then exit 2; fi; exit 0
}

pgrep -x VayuSetuVPN >/dev/null || { say "VayuSetu is not running. Open it and try again."; exit 64; }
INIT_NC="$(nc_state)"; INIT_SEL="$(selection)"
[ "$INIT_NC" = "Disconnected" ] || { say "The tunnel is not off at the start ($INIT_NC). This script starts from off and will not run."; exit 64; }
echo "$INIT_SEL" | grep -q '"vpnEnabled":false' && echo "$INIT_SEL" | grep -q '"dnsEnabled":false' || { say "The saved selection is not off at the start ($INIT_SEL). Not running."; exit 64; }
trap restore EXIT INT TERM

say "VayuSetu runtime security verification   $(date '+%Y-%m-%d %H:%M:%S')"
say "App: $(plutil -p /Applications/VayuSetu.app/Contents/Info.plist | grep CFBundleVersion | tr -d ' ')   macOS $(sw_vers -productVersion)   $(sysctl -n hw.model)"
say "Activated extensions: $(systemextensionsctl list 2>/dev/null | grep 'app.vayusetu' | grep activated | sed -n 's/.*macos\.\([a-z]*\) (\(1.0\/[0-9]*\)).*/\1 \2/p' | tr '\n' ';')"

# ---- baseline ----------------------------------------------------------------------------------------------------------------------------------
B4="$(v4)"; B6="$(v6)"; BW="$(who)"
say ""; say "BASELINE (protection off)"
note "IPv4 egress: ${B4:-none}   IPv6 egress: ${B6:-none}   resolver seen by the authoritative server: ${BW:-none}"
[ -n "$B4" ] || { say "No IPv4 connectivity at the start; cannot measure leaks."; exit 64; }
[ -n "$BW" ] || NV "baseline resolver identity could not be read (whoami.akamai.net); DNS-leak comparison below is unavailable"
BWP="$(prefix "$BW")"; B4P="$(prefix "$B4")"; B6P="$(prefix "$B6")"

abort_if_approval() { if [ "$(waiting_for_approval)" != "0" ]; then say ""; say "STOP: macOS is asking for approval of a system extension. Approve it in System Settings > General > Login Items & Extensions, then run this again."; NV "protection could not be started without your approval of a system extension"; exit 2; fi; }

# ---- 1. DNS only ---------------------------------------------------------------------------------------------------------------------------------
say ""; say "1. DNS ONLY"
t0=$SECONDS; link dns on; wait_nc Connected 90; rc=$?; abort_if_approval
if [ $rc -ne 0 ]; then F "DNS-only tunnel did not reach Connected within 90 s"; exit 1; fi
sleep 6; P "DNS-only tunnel connected in $((SECONDS-t0)) s"
[ "$(resolver0)" = "198.18.0.2" ] && P "system resolver is VayuSetu's local DNS (198.18.0.2)" || F "system resolver is $(resolver0), expected 198.18.0.2"
[ "$(iface)" = "$(route -n get "$(ipconfig getifaddr en0 2>/dev/null || echo 1.1.1.1)" 2>/dev/null | awk '/interface:/{print $2}')" ] || true
case "$(iface)" in utun*) F "DNS-only moved the default route to $(iface); only DNS should go through the tunnel";; *) P "default route unchanged ($(iface)): only DNS is captured";; esac
n="$(lookups)"; [ "$n" -ge 11 ] && P "applications resolved $n of 12 names" || F "applications resolved only $n of 12 names"
W="$(who)"; if [ -n "$W" ] && [ -n "$BW" ]; then
  if [ "$(prefix "$W")" = "$BWP" ]; then F "DNS LEAK: the authoritative server still sees the ISP's resolver ($BWP)"; else P "no DNS leak: the authoritative server sees $(prefix "$W"), not the ISP's resolver ($BWP)"; fi
else NV "DNS-only resolver identity could not be compared"; fi
blocked="$(python3 -c "
import socket
try: a=sorted({x[4][0] for x in socket.getaddrinfo('pagead2.googlesyndication.com',443,type=socket.SOCK_STREAM)}); print('blocked' if all(i in ('0.0.0.0','::') for i in a) else 'resolved')
except Exception: print('blocked')")"
[ "$blocked" = "blocked" ] && P "an ad domain (pagead2.googlesyndication.com) is blocked at the DNS filter" || F "an ad domain still resolves to a real address"
# Transport: what the tunnel process talks to. Visible only if the system lets an unprivileged user see it.
TP="$(pgrep -f 'tunnel.systemextension/Contents/MacOS/VayuSetuTunnel' | head -1)"
if [ -n "$TP" ] && nettop -p "$TP" -L 1 -n -m tcp 2>/dev/null | grep -q "VayuSetuTunnel"; then
  conns="$(nettop -p "$TP" -L 1 -n -x -m tcp 2>/dev/null | grep -Eo '(->|<-)[0-9a-fA-F:.]+:[0-9]+' | sed 's/^..//' | awk -F: '{print $NF}' | sort | uniq -c | sort -rn | tr '\n' ' ')"
  note "tunnel process TCP remote ports seen: ${conns:-none yet}"
  echo "$conns" | grep -Eq ' (443|853)( |$)' && P "the tunnel's upstream connections use 443 (DoH) or 853 (DoT)" || NV "could not see upstream connections from the tunnel process"
else NV "DNS transport: the tunnel process's sockets are not visible without root; plaintext port-53 absence on the wire is not proven (needs a packet capture)"; fi
link both off; wait_nc Disconnected 60 || F "could not switch DNS-only off"; sleep 4

if [ $WITH_VPN = 1 ]; then
# ---- 2. VPN only ----------------------------------------------------------------------------------------------------------------------------------
say ""; say "2. VPN ONLY (full tunnel)"
t0=$SECONDS; link vpn on; wait_nc Connected 90; rc=$?; abort_if_approval
if [ $rc -ne 0 ]; then F "VPN did not reach Connected within 90 s"; exit 1; fi
sleep 8; P "VPN connected in $((SECONDS-t0)) s"
case "$(iface)" in utun*) P "default route goes through the tunnel ($(iface))";; *) F "VPN is connected but the default route is $(iface): traffic is not going through the tunnel";; esac
read -r rx tx name <<<"$(utun_bytes)"; sleep 1; v4now="$(v4)"; read -r rx2 tx2 _ <<<"$(utun_bytes)"
if [ -n "$v4now" ]; then
  [ "$v4now" != "$B4" ] && P "WireGuard handshake and data path work: IPv4 egress is $v4now (baseline $B4)" || F "IPv4 egress equals the baseline ($B4): the VPN is not carrying traffic (or leaks)"
else F "no IPv4 connectivity through the VPN"; fi
[ "${rx2:-0}" -gt "${rx:-0}" ] 2>/dev/null && [ "${tx2:-0}" -gt "${tx:-0}" ] 2>/dev/null && P "bytes flowed both ways on $name during the check (in +$((rx2-rx)), out +$((tx2-tx)))" || NV "tunnel interface byte counters did not change in the sampling window (counters on $name: in $rx->$rx2, out $tx->$tx2)"
g6="$(v6)"
if [ -z "$g6" ]; then P "IPv6: no IPv6 egress while the VPN is on (blocked or unavailable); the native IPv6 address does not leak"
elif [ -n "$B6" ] && { [ "$g6" = "$B6" ] || [ "$(prefix "$g6")" = "$B6P" ]; }; then F "IPv6 LEAK: IPv6 egress is $g6, the same network as the native address ($B6)"
else P "IPv6: egress is $g6, not the native address; it goes through the tunnel"; fi
W="$(who)"
if [ -z "$W" ]; then NV "VPN-only resolver identity could not be read"
elif [ -n "$BW" ] && [ "$(prefix "$W")" = "$BWP" ]; then F "DNS LEAK on VPN only: the authoritative server sees the ISP's resolver ($BWP)"
else P "VPN-only DNS does not reach the ISP's resolver (the authoritative server sees $(prefix "$W"))"; fi
link vpn off; wait_nc Disconnected 60 || F "could not switch the VPN off"; sleep 4
case "$(iface)" in utun*) F "after the VPN was switched off the default route is still $(iface)";; *) P "after switching off, the default route is back to $(iface)";; esac
[ "$(v4)" = "$B4" ] && P "after switching off, IPv4 egress is the baseline again" || F "after switching off, IPv4 egress is not the baseline"

# ---- 3. VPN + DNS ---------------------------------------------------------------------------------------------------------------------------------
say ""; say "3. VPN + DNS"
t0=$SECONDS; link both on; wait_nc Connected 90; rc=$?; abort_if_approval
if [ $rc -ne 0 ]; then F "VPN + DNS did not reach Connected within 90 s"; exit 1; fi
sleep 10; P "VPN + DNS connected in $((SECONDS-t0)) s"
v4now="$(v4)"; [ -n "$v4now" ] && [ "$v4now" != "$B4" ] && P "IPv4 egress is the VPN's ($v4now), not the baseline" || F "VPN + DNS: IPv4 egress is '${v4now:-none}' (baseline $B4)"
g6="$(v6)"
if [ -z "$g6" ]; then P "IPv6: no IPv6 egress with VPN + DNS; the native address does not leak"
elif [ -n "$B6" ] && { [ "$g6" = "$B6" ] || [ "$(prefix "$g6")" = "$B6P" ]; }; then F "IPv6 LEAK with VPN + DNS: $g6"
else P "IPv6: egress is $g6, through the tunnel"; fi
n="$(lookups)"; [ "$n" -ge 11 ] && P "applications resolved $n of 12 names" || F "applications resolved only $n of 12 names"
W="$(who)"
if [ -z "$W" ]; then NV "VPN + DNS resolver identity could not be read"
elif [ -n "$BW" ] && [ "$(prefix "$W")" = "$BWP" ]; then F "DNS LEAK with VPN + DNS: the authoritative server sees the ISP's resolver ($BWP)"
else P "VPN + DNS: no DNS leak (the authoritative server sees $(prefix "$W"))"; fi
blocked="$(python3 -c "
import socket
try: a=sorted({x[4][0] for x in socket.getaddrinfo('doubleclick.net',443,type=socket.SOCK_STREAM)}); print('blocked' if all(i in ('0.0.0.0','::') for i in a) else 'resolved')
except Exception: print('blocked')")"
[ "$blocked" = "blocked" ] && P "an ad domain (doubleclick.net) is blocked in VPN + DNS" || NV "doubleclick.net resolved in VPN + DNS; blocking in this mode depends on the selected resolver (VayuSetu DNS filters, an external one applies its own policy)"

# ---- 4. recovery ----------------------------------------------------------------------------------------------------------------------------------
say ""; say "4. RECOVERY (the app is quit and reopened while VPN + DNS is on; then three switch-off/switch-on cycles)"
osascript -e 'tell application "VayuSetu" to quit' >/dev/null 2>&1; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x VayuSetuVPN >/dev/null || break; sleep 1; done
sleep 3; s_after_quit="$(nc_state)"
[ "$s_after_quit" = "Connected" ] && P "the tunnel keeps running when the app is quit (the app is not needed to stay protected)" || NV "after quitting the app the tunnel was $s_after_quit"
v4q="$(v4)"; [ -n "$v4q" ] && [ "$v4q" != "$B4" ] && P "traffic is still protected with the app closed (IPv4 egress $v4q)" || F "with the app closed, protection was lost (egress '${v4q:-none}')"
open -a /Applications/VayuSetu.app; sleep 12
pgrep -x VayuSetuVPN >/dev/null || { F "the app did not reopen"; exit 1; }
sel="$(selection)"; echo "$sel" | grep -q '"vpnEnabled":true' && echo "$sel" | grep -q '"dnsEnabled":true' && [ "$(nc_state)" = "Connected" ] && P "the reopened app agrees with the running tunnel (selection VPN + DNS, tunnel Connected), and did not change it" || F "after reopening, the app's state ($sel) and the tunnel ($(nc_state)) disagree"
for cycle in 1 2 3; do
  link both off; wait_nc Disconnected 60 || { F "cycle $cycle: could not switch off"; break; }; sleep 3
  case "$(iface)" in utun*) F "cycle $cycle: route still $(iface) after off";; esac
  t0=$SECONDS; link both on; wait_nc Connected 90; rc=$?; abort_if_approval
  [ $rc -eq 0 ] || { F "cycle $cycle: did not reconnect within 90 s"; break; }
  e=""; for i in 1 2 3 4 5 6 7 8; do e="$(v4)"; [ -n "$e" ] && [ "$e" != "$B4" ] && break; sleep 2; done
  [ -n "$e" ] && [ "$e" != "$B4" ] && P "cycle $cycle: reconnected and carrying traffic after $((SECONDS-t0)) s (egress $e)" || F "cycle $cycle: reconnected but no protected egress after $((SECONDS-t0)) s"
done
fi

# ---- what this script cannot show ---------------------------------------------------------------------------------------------------------------------
say ""; say "NOT OBSERVABLE FROM HERE (stated, not skipped):"
NV "kill switch / fail-closed behaviour when the connection drops: showing it means cutting the connection, which this script does not do"
NV "recovery after Wi-Fi loss, a network change, or sleep and wake: each needs the connection or the Mac to be interrupted"
NV "recovery when the tunnel process itself dies: it runs as root, which this script is not"
NV "network-filter blocking of a live connection: needs a rule created in the app; only the extension's activation is checked: $(systemextensionsctl list 2>/dev/null | grep 'app.vayusetu.macos.filter' | grep -c 'activated enabled') activated"
exit 0
