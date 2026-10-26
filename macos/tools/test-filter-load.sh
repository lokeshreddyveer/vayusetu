#!/bin/bash
# Opens many short connections and watches what the installed network filter costs while it decides them.
# Each connection is one UDP lookup made by /usr/bin/dig, which macOS signs (so, with "Let Apple-signed software connect" on, it is
# never held for a question). Needs the network filter switched on in VayuSetu.
#
#   macos/tools/test-filter-load.sh [connections] [parallel]      default 3000 and 40
set -u
N="${1:-3000}"; P="${2:-40}"
PID="$(pgrep -x VayuSetuFilter | head -1)"
[ -n "$PID" ] || { echo "The network filter is not running. Switch it on in VayuSetu (Network page) and try again."; exit 2; }
sample() { ps -o %cpu=,rss= -p "$PID" 2>/dev/null | awk '{printf "%s %.0f", $1, $2/1024}'; }
echo "Filter process $PID. Before: CPU% / memory MB = $(sample)"
LOG="$(mktemp)"
( while kill -0 $$ 2>/dev/null && [ -f "$LOG" ]; do sample >> "$LOG.samples"; echo >> "$LOG.samples"; sleep 0.5; done ) &
SAMPLER=$!
START=$(python3 -c 'import time;print(time.time())')
seq 1 "$N" | xargs -P "$P" -I{} sh -c '/usr/bin/dig +tries=1 +time=1 +short x{}.vayusetu-load.invalid @192.0.2.1 >/dev/null 2>&1'
END=$(python3 -c 'import time;print(time.time())')
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
python3 - "$N" "$START" "$END" "$LOG.samples" <<'PY'
import sys
n,s,e,f=int(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3]),sys.argv[4]
rows=[l.split() for l in open(f) if len(l.split())==2]
cpu=[float(r[0]) for r in rows]; mem=[float(r[1]) for r in rows]
print(f"{n} connections in {e-s:.1f} s ({n/(e-s):.0f}/s)")
if rows: print(f"Filter during the run: CPU peak {max(cpu):.0f}%, average {sum(cpu)/len(cpu):.0f}%; memory peak {max(mem):.0f} MB")
PY
rm -f "$LOG" "$LOG.samples"
echo "After: CPU% / memory MB = $(sample)"
