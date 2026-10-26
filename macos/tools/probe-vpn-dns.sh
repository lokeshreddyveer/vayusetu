#!/bin/bash
# Executes Docs/Testing/VPN-DNS-No-Traffic-Test-Plan.md: A (VPN only), B (VPN + DNS), C (VPN + DNS again), E (control, app open), D (app quit), then restores protection off.
set -u
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Documents/VayuSetu/macos/test-evidence/probe-plan-$STAMP.txt"; : > "$OUT"
PREFS="$HOME/Library/Preferences/app.vayusetu.macos.plist"
log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT"; }
nc_state() { scutil --nc list | grep 'VayuSetu ·' | sed -E 's/^\* \(([A-Za-z]+)\).*/\1/'; }
sel() { plutil -extract protection-selection raw -o - "$PREFS" 2>/dev/null | base64 -d 2>/dev/null; }
iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
dns0() { scutil --dns | awk '/nameserver\[0\]/{print $3; exit}'; }
approval() { systemextensionsctl list 2>/dev/null | grep -i vayusetu | grep -ciE 'waiting for user|awaiting'; }
link() { open "vayusetu://protection/$1/$2"; }
utun_bytes() { local i; i="$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')"; case "$i" in utun*) netstat -ib -I "$i" 2>/dev/null | awk 'NR==2{print "in="$7" out="$10}';; *) echo "no-tunnel-route($i)";; esac; }
ADDR="$(python3 -c "import socket;print(socket.getaddrinfo('api64.ipify.org',443,socket.AF_INET)[0][4][0])" 2>/dev/null)"
NAMES=(www.wikipedia.org www.mozilla.org www.python.org www.gnu.org www.kernel.org www.debian.org www.apache.org www.openbsd.org www.eff.org www.w3.org www.ietf.org www.iana.org)
NI=0
probe_set() { # label
  local L="$1" h l t d big small ok=0
  h="$(curl -4 -s --max-time 8 -w ' host: dns=%{time_namelookup} connect=%{time_connect} total=%{time_total}' https://api64.ipify.org 2>&1)"
  l="$(curl -4 -s --max-time 8 --resolve "api64.ipify.org:443:$ADDR" -w ' literal: connect=%{time_connect} total=%{time_total}' https://api64.ipify.org 2>&1)"
  t="$(python3 - "$ADDR" <<'PY'
import socket,sys,time
t=time.time()
try:
    s=socket.create_connection((sys.argv[1],443),timeout=5); s.close(); print("tcp ok %.3fs"%(time.time()-t))
except Exception as e: print("tcp FAIL %s after %.1fs"%(type(e).__name__,time.time()-t))
PY
)"
  local name="${NAMES[$((NI % ${#NAMES[@]}))]}"; NI=$((NI+1))
  d="$(python3 - "$name" <<'PY'
import socket,sys,time
t=time.time()
try:
    socket.getaddrinfo(sys.argv[1],443,socket.AF_INET); print("lookup %s ok %.3fs"%(sys.argv[1],time.time()-t))
except Exception as e: print("lookup %s FAIL %s after %.1fs"%(sys.argv[1],type(e).__name__,time.time()-t))
PY
)"
  big="$(ping -c 2 -W 2000 -D -s 1372 1.1.1.1 2>&1 | awk '/packets transmitted/{print "big "$7" loss"}')"
  small="$(ping -c 2 -W 2000 -s 56 1.1.1.1 2>&1 | awk '/packets transmitted/{print "small "$7" loss"}')"
  log "$L | $h | $l | $t | $d | $big | $small | iface=$(iface) resolver=$(dns0) bytes[$(utun_bytes)]"
  local ip="${h%% *}"; local ip2="${l%% *}"
  [[ "$ip" =~ ^[0-9.]+$ && "$ip" != "$BASE" ]] && echo host > "$TMPDIR/probe_ok"
  [[ "$ip2" =~ ^[0-9.]+$ && "$ip2" != "$BASE" ]] && echo literal >> "$TMPDIR/probe_ok"
}
schedule() { # label offsets... ; returns 0 if any probe through the tunnel worked
  local label="$1"; shift; : > "$TMPDIR/probe_ok"; local t0=$SECONDS o
  for o in "$@"; do
    local now=$((SECONDS-t0)); [ "$now" -lt "$o" ] && sleep $((o-now))
    probe_set "$label +$((SECONDS-t0))s"
  done
  [ -s "$TMPDIR/probe_ok" ]
}
abort_approval() { if [ "$(approval)" != "0" ]; then log "STOP: a system-extension approval prompt is waiting. Nothing further was changed."; exit 3; fi; }
wait_state() { local t=0; while [ $t -lt "$2" ]; do [ "$(nc_state)" = "$1" ] && { log "state $1 after ${t}s"; return 0; }; abort_approval; sleep 1; t=$((t+1)); done; log "TIMEOUT waiting for $1 after ${2}s (state $(nc_state))"; return 1; }
restore() {
  log "RESTORE: both off, vpn off, dns off"
  pgrep -x VayuSetuVPN >/dev/null || { open -a /Applications/VayuSetu.app; sleep 12; }
  link both off; wait_state Disconnected 60; sleep 2; link vpn off; sleep 2; link dns off; sleep 6
  log "restored: state=$(nc_state) selection=$(sel) iface=$(iface) resolver=$(dns0) app=$(pgrep -x VayuSetuVPN >/dev/null && echo running || echo NOT-running)"
  log "egress after restore: $(curl -4 -s --max-time 8 https://api64.ipify.org) (baseline $BASE)"
}
stop_no_traffic() { log "STOP: tunnel Connected but no traffic through it for the whole schedule ($1)"; restore; exit 4; }
OFFS=(1 3 6 12 24)
pgrep -x VayuSetuVPN >/dev/null || { log "app not running"; exit 64; }
log "BUILD $(defaults read /Applications/VayuSetu.app/Contents/Info CFBundleVersion) app-sha $(shasum -a 256 /Applications/VayuSetu.app/Contents/MacOS/VayuSetuVPN | cut -c1-16) commit $(cat "$HOME/Documents/VayuSetu/macos/build/test-build-logs/diag-defb246/commit.txt")"
log "extensions: $(systemextensionsctl list 2>/dev/null | grep -E 'vayusetu.macos.(tunnel|filter)' | grep -v 'waiting to uninstall' | awk '{print $4,$5}' | tr '\n' ' ')"
[ "$(nc_state)" = Disconnected ] && echo "$(sel)" | grep -q '"vpnEnabled":false' && echo "$(sel)" | grep -q '"dnsEnabled":false' || { log "not starting from off"; exit 64; }
BASE="$(curl -4 -s --max-time 8 https://api64.ipify.org)"; log "baseline egress $BASE, api64.ipify.org -> $ADDR, state=$(nc_state) selection=$(sel)"
[ -n "$BASE" ] && [ -n "$ADDR" ] || { log "no baseline"; exit 64; }
# A: VPN only
log "== A: VPN only"; link vpn on; wait_state Connected 90 || { restore; exit 5; }; schedule A "${OFFS[@]}" || stop_no_traffic A
link vpn off; wait_state Disconnected 60 || { restore; exit 5; }; sleep 4
# B: VPN + DNS, first connect
log "== B: VPN + DNS"; link both on; T=$SECONDS; wait_state Connected 90 || { restore; exit 5; }; log "B connect took $((SECONDS-T))s"; schedule B "${OFFS[@]}" || stop_no_traffic B
# C: VPN + DNS again, 5 s after off
log "== C: off, 5 s, on again"; link both off; wait_state Disconnected 60 || { restore; exit 5; }; sleep 5
link both on; T=$SECONDS; wait_state Connected 90 || { log "C did not reconnect"; restore; exit 5; }; log "C connect took $((SECONDS-T))s"; schedule C "${OFFS[@]}" || stop_no_traffic C
# E: control, app open, same offsets as D
log "== E: control, app left open"; schedule E "${OFFS[@]}" || stop_no_traffic E
# D: quit the app
log "== D: quit the app while connected"; osascript -e 'tell application "VayuSetu" to quit' >/dev/null 2>&1
for i in $(seq 1 10); do pgrep -x VayuSetuVPN >/dev/null || break; sleep 1; done
log "D app quit: running=$(pgrep -x VayuSetuVPN >/dev/null && echo yes || echo no) tunnel=$(nc_state)"
schedule D "${OFFS[@]}" || log "RESULT D: no traffic through the tunnel with the app closed"
log "D tunnel after schedule: $(nc_state)"
open -a /Applications/VayuSetu.app; sleep 12; log "reopened: running=$(pgrep -x VayuSetuVPN >/dev/null && echo yes || echo no) tunnel=$(nc_state) selection=$(sel)"; schedule D2 1 3 || true
restore
log "DONE. Evidence: $OUT"
