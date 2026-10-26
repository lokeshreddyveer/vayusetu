#!/bin/bash
# Connection cycle test for the installed Mac app. It drives VayuSetu with its own vayusetu:// links and checks the real outcome
# after every step (the tunnel's state, the public address, whether a lookup is answered and a blocked name is blocked), then
# looks for tunnel start-up failures in the log. Nothing is mocked.
#
#   macos/tools/test-connect.sh [cycles]      # default 1 cycle
#
# Needs: /Applications/VayuSetu.app installed and running, a saved VPN profile that is selected, and a working network.
# It records the protection state first (VPN, DNS, Safari Adblock, selected resolver and profile), changes only VPN and DNS while it runs,
# and puts them back as they were at the end, on success, failure or interrupt. It never touches Safari Adblock, system DNS settings,
# VPN configurations or profiles. If the original state cannot be verified afterwards it stops and exits with status 3.
set -u
CYCLES="${1:-1}"
BLOCKED="pagead2.googlesyndication.com"
GOOD="example.com"
LOCAL_DNS="198.18.0.2"
SETTLE=45

pass=0; fail=0; failures=()
say()  { printf '%s\n' "$*"; }
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); failures+=("$1"); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Why an address service could not be used: resolution failed, the name is blocked by policy (answered with a null address), the TCP
# connection failed, it timed out, or the service answered something that is not an address. Written to $PROBE_LOG so that a blocked
# name is never mistaken for a broken connection. Names are resolved the way applications do (getaddrinfo), not with dig.
PROBE_LOG="${PROBE_LOG:-${TMPDIR:-/tmp}/vayusetu-probe-kinds.log}"
classify_host() { # classify_host <host> -> dns-failure | blocked-by-policy | tcp-failure | timeout | ok
  local addrs; addrs="$(python3 -c "import socket;print(' '.join(sorted({a[4][0] for a in socket.getaddrinfo('$1',443,type=socket.SOCK_STREAM)})))" 2>/dev/null)"
  if [ -z "$addrs" ]; then echo dns-failure; return; fi
  if ! tr ' ' '\n' <<<"$addrs" | grep -vqxE '0\.0\.0\.0|::'; then echo blocked-by-policy; return; fi
  curl -s -o /dev/null --max-time 6 "https://$1/" 2>/dev/null; case $? in 0|22|35|60) echo ok;; 28) echo timeout;; 7) echo tcp-failure;; *) echo tcp-failure;; esac
}
# The public address, from the first of several services that can be used. A service that is blocked or unreachable is recorded and skipped.
public_ip() {
  local host ip kind
  for host in api.ipify.org ifconfig.me icanhazip.com; do
    ip="$(curl -s --max-time 8 "https://$host$([ $host = ifconfig.me ] && echo /ip)" 2>/dev/null | tr -d ' \n')"
    if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] && [[ "$ip" == *.* || "$ip" == *:* ]]; then echo "$ip"; return; fi
    kind="$(classify_host $host)"; echo "$(date +%T) $host $kind" >> "$PROBE_LOG"
  done
}
nc_line()   { scutil --nc list 2>/dev/null | grep -i "app.vayusetu.macos" | head -1; }
nc_connected() { nc_line | grep -q "(Connected)"; }
nc_off()       { ! nc_line | grep -qE "\((Connected|Connecting|Reasserting|Disconnecting)\)"; }
resolves()  { [ -n "$(dig +short +time=3 +tries=1 "$1" @$LOCAL_DNS 2>/dev/null | head -1)" ]; }
# A blocked name is answered either with NXDOMAIN or with NOERROR and a null address (0.0.0.0 or ::). Which one is recorded in $BLOCK_LOG.
BLOCK_LOG="${BLOCK_LOG:-${TMPDIR:-/tmp}/vayusetu-block-kinds.log}"
block_kind() {
  local out; out="$(dig +time=3 +tries=1 "$1" @$LOCAL_DNS 2>/dev/null)"
  if grep -q "status: NXDOMAIN" <<<"$out"; then echo "NXDOMAIN"
  elif grep -q "status: NOERROR" <<<"$out" && dig +short +time=3 +tries=1 "$1" @$LOCAL_DNS 2>/dev/null | grep -qxE '0\.0\.0\.0|::'; then echo "NOERROR-null-address"
  else echo "not-blocked"; fi
}
is_blocked() { local k; k="$(block_kind "$1")"; [ "$k" != "not-blocked" ] && { echo "$(date +%T) $1 $k" >> "$BLOCK_LOG"; return 0; }; return 1; }
link()      { open "vayusetu://protection/$1/$2"; }

wait_for() { # wait_for <seconds> <command...>
  local limit=$1; shift; local t=0
  while [ $t -lt "$limit" ]; do if eval "$*"; then return 0; fi; sleep 2; t=$((t+2)); done
  return 1
}

# Tunnel start-up failures since a given time (epoch seconds), from the public startup log.
failures_since() {
  /usr/bin/log show --start "$(date -r "$1" '+%Y-%m-%d %H:%M:%S')" --info \
    --predicate 'subsystem == "app.vayusetu.tunnel" AND eventMessage CONTAINS " failed "' --style compact 2>/dev/null \
    | grep -v '^Timestamp\|^Filtering' | sed 's/.*startup //' | sort | uniq -c
}

# ---- recorded state and restoration ----
PREFS="$HOME/Library/Preferences/app.vayusetu.macos.plist"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/vayusetu-test-state}"; mkdir -p "$STATE_DIR"
pref()      { plutil -extract "$1" raw -o - "$PREFS" 2>/dev/null; }
sel_field() { pref protection-selection | base64 -d 2>/dev/null | python3 -c "import sys,json;print(str(json.load(sys.stdin).get('$1')).lower())" 2>/dev/null; }
default_iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
first_resolver() { scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}'; }
nc_state()  { nc_line | sed -n 's/.*(\([A-Za-z]*\)).*/\1/p'; }
snapshot() { # snapshot <file>
  { echo "vpn_selected=$(sel_field vpnEnabled)"; echo "dns_selected=$(sel_field dnsEnabled)"; echo "adblock_selected=$(sel_field safariAdblockEnabled)"
    echo "selected_dns=$(pref selected-dns)"; echo "selected_profile=$(pref selected-profile)"
    echo "nc_state=$(nc_state)"; echo "default_iface=$(default_iface)"; echo "first_resolver=$(first_resolver)"; } > "$1"
}
snapshot "$STATE_DIR/initial.txt"
get() { grep "^$2=" "$1" | cut -d= -f2-; }
INIT_VPN="$(get "$STATE_DIR/initial.txt" vpn_selected)"; INIT_DNS="$(get "$STATE_DIR/initial.txt" dns_selected)"
INIT_NC="$(get "$STATE_DIR/initial.txt" nc_state)"
for v in "$INIT_VPN" "$INIT_DNS" "$(get "$STATE_DIR/initial.txt" adblock_selected)" "$INIT_NC"; do
  case "$v" in true|false|Disconnected|Connected|Connecting|Reasserting|Disconnecting) ;; *) say "The starting protection state could not be read ('$v'). Nothing was changed."; trap - EXIT INT TERM; exit 2;; esac
done

restoring=0
restore() { # puts VPN and DNS back as recorded, then verifies with independent evidence
  [ "$restoring" = 1 ] && return; restoring=1; trap - EXIT INT TERM
  say ""; say "Restoring the recorded state (VPN selected: $INIT_VPN, DNS selected: $INIT_DNS)"
  pgrep -x VayuSetuVPN >/dev/null || { say "RESTORE NOT VERIFIED: the app is not running, so its links cannot be used."; exit 3; }
  if [ "$INIT_VPN" = "false" ] && [ "$INIT_DNS" = "false" ]; then link both off
  else # one change at a time, each given time to settle, so the second never reads a stale snapshot
    if [ "$INIT_VPN" = "false" ]; then link vpn off; else link vpn on; fi; sleep 12
    if [ "$INIT_DNS" = "false" ]; then link dns off; else link dns on; fi
  fi
  if [ "$INIT_NC" = "Disconnected" ] || [ -z "$INIT_NC" ]; then wait_for $SETTLE nc_off; else wait_for $SETTLE nc_connected; fi
  local tries=0; sleep 3; snapshot "$STATE_DIR/final.txt"
  while [ $tries -lt 5 ] && ! diff -q <(grep -E "^(vpn|dns|adblock)_selected=" "$STATE_DIR/initial.txt") <(grep -E "^(vpn|dns|adblock)_selected=" "$STATE_DIR/final.txt") >/dev/null; do sleep 3; snapshot "$STATE_DIR/final.txt"; tries=$((tries+1)); done
  local bad=0
  for k in vpn_selected dns_selected adblock_selected selected_dns selected_profile nc_state; do
    if [ "$(get "$STATE_DIR/initial.txt" $k)" != "$(get "$STATE_DIR/final.txt" $k)" ]; then say "  MISMATCH $k: was '$(get "$STATE_DIR/initial.txt" $k)' now '$(get "$STATE_DIR/final.txt" $k)'"; bad=1; fi
  done
  # Independent evidence: routes and resolver must agree with the recorded state, whatever the public address is.
  if [ "$INIT_VPN" = "false" ] && [[ "$(default_iface)" == utun* ]]; then say "  MISMATCH default route still goes through $(default_iface)"; bad=1; fi
  if [ "$INIT_DNS" = "false" ] && [ "$(first_resolver)" = "$LOCAL_DNS" ]; then say "  MISMATCH system resolver is still VayuSetu's $LOCAL_DNS"; bad=1; fi
  if [ $bad = 0 ]; then say "RESTORED and verified: tunnel state, selections, default route and resolver match the recorded state"; exit ${RESULT:-0}
  else say "RESTORE NOT VERIFIED. Stopping. Nothing further has been changed. Recorded: $STATE_DIR/initial.txt  Current: $STATE_DIR/final.txt"; exit 3; fi
}
trap restore EXIT INT TERM

# ---- preflight ----
pgrep -x VayuSetuVPN >/dev/null || { say "VayuSetu is not running. Open /Applications/VayuSetu.app and try again."; exit 2; }
[ "$INIT_NC" = "Disconnected" ] || { say "The tunnel was not off when the test started ($INIT_NC). This run starts from off, so it will not run."; trap - EXIT INT TERM; exit 2; }
say "Recorded state: $(tr '\n' ' ' < "$STATE_DIR/initial.txt")"
BASE_IP="$(public_ip)"
[ -n "$BASE_IP" ] || { say "No internet: could not read the public address."; exit 2; }
say "Baseline public address: $BASE_IP"
START=$(date +%s)

expect_off() {
  check "tunnel is off" "nc_off"
  check "public address is the baseline" "[ \"\$(public_ip)\" = \"$BASE_IP\" ]"
}
expect_dns_only() {
  check "tunnel connected" "wait_for $SETTLE nc_connected"
  check "a normal name resolves through the tunnel" "wait_for 20 resolves $GOOD"
  check "a blocked name is blocked" "wait_for 30 is_blocked $BLOCKED"
  check "public address is back to normal (no VPN)" "wait_for 30 '[ \"\$(public_ip)\" = \"$BASE_IP\" ]'"
}
expect_vpn_only() {
  check "tunnel connected" "wait_for $SETTLE nc_connected"
  check "public address changed" "wait_for 25 '[ -n \"\$(public_ip)\" ] && [ \"\$(public_ip)\" != \"$BASE_IP\" ]'"
}
expect_vpn_dns() {
  check "tunnel connected" "wait_for $SETTLE nc_connected"
  check "public address changed" "wait_for 25 '[ -n \"\$(public_ip)\" ] && [ \"\$(public_ip)\" != \"$BASE_IP\" ]'"
  check "a normal name resolves through the tunnel" "wait_for 20 resolves $GOOD"
  check "a blocked name is blocked" "wait_for 30 is_blocked $BLOCKED"
}
# One atomic link switches both off. Two links in quick succession race: the second reads a snapshot that still shows the first one's tunnel
# as running and applies it again. protection/both/off changes VPN and DNS only; Safari Adblock keeps its setting.
all_off() { link both off; wait_for $SETTLE nc_off; }

for cycle in $(seq 1 "$CYCLES"); do
  say ""; say "=== Cycle $cycle of $CYCLES ==="

  say "-- DNS only"
  link dns on;  expect_dns_only
  say "-- DNS only -> VPN + DNS"
  link vpn on;  expect_vpn_dns
  say "-- VPN + DNS -> DNS only"
  link vpn off; expect_dns_only
  say "-- DNS only -> off"
  all_off;      expect_off

  say "-- VPN only"
  link vpn on;  expect_vpn_only
  say "-- VPN only -> VPN + DNS"
  link dns on;  expect_vpn_dns
  say "-- VPN + DNS -> VPN only"
  link dns off; expect_vpn_only
  say "-- VPN only -> off"
  all_off;      expect_off

  say "-- VPN + DNS in one request, from off"
  link both on
  check "tunnel connected" "wait_for 60 nc_connected"
  check "public address changed" "wait_for 60 '[ -n \"\$(public_ip)\" ] && [ \"\$(public_ip)\" != \"$BASE_IP\" ]'"
  check "a normal name resolves through the tunnel" "wait_for 30 resolves $GOOD"
  check "a blocked name is blocked (within 40 s)" "wait_for 40 is_blocked $BLOCKED"
  say "-- stop during a start (off straight after on)"
  all_off
  link vpn on; sleep 2; link vpn off
  check "ends off after a quick on and off" "wait_for $SETTLE nc_off"
  expect_off
done

all_off
say ""; say "=== Start-up failures logged by the tunnel during this run ==="
f="$(failures_since "$START")"
if [ -z "$f" ]; then say "  none"; else say "$f"; fi
say ""; say "Result: $pass passed, $fail failed."
RESULT=0
if [ "$fail" -gt 0 ]; then printf '  - %s\n' "${failures[@]}"; RESULT=1; fi
say "Blocked-name answers seen (time name kind) are in $BLOCK_LOG"
exit $RESULT
