# Mac screen tour: frames, jank, CPU and hangs on every screen

A debug-only walk through every page of the Mac app and every tab and drill-down screen it can reach. It measures how smoothly each one draws and
how much CPU it uses, and it never changes a setting.

## Run it

    macos/tools/build-perf.sh                    # builds build/perf-app/VayuSetuPerf.app (optimised, debug tour included, own bundle id, no extensions)
    macos/tools/perf-tour.py run                 # tours every page, saves macos/test-evidence/perf-tour-<time>.json, then judges it
    macos/tools/perf-tour.py run --pages "Home,Settings"
    macos/tools/perf-tour.py check FILE          # judge a saved report again (exit 1 when a limit is broken)
    macos/tools/perf-tour.py show FILE           # every step

For looking at the design instead of timing it, add screenshots (slower; CPU numbers from such a run are not valid because saving PNGs costs CPU):

    build/perf-app/VayuSetuPerf.app/Contents/MacOS/VayuSetu --perf-tour out.json --perf-shots DIR [--perf-width 1180]

## What it measures, per step

`enter` (opening a page), `tab`, `push` and `pop` (drill-down screens), `scroll` (top to bottom and back in 2 s), `idle` (after a short settle).
Each records frames drawn, frame-gap percentiles, hitches (a gap over 1.5 times normal), dropped frames, CPU share of one core, and memory.
Limits live at the top of `perf-tour.py`: motion steps need p99 under 2.2 times the normal gap and under 4 % dropped; idle steps need CPU under 6 %.

## Safety and self-diagnosis

* Only controls tagged `.perfTarget("tab.…")` or `.perfTarget("nav.…")` are clicked. The sidebar is driven by a notification. Nothing can start
  protection, save a setting or delete data. `perfTarget` compiles to nothing in release builds.
* A watchdog thread reports a hang: if the main thread does not answer for 8 s it samples the stack, writes `<report>.hang.txt` and
  `<report>.hang-sample.txt` naming the screen, and exits with status 3. The tour can no longer sit frozen.
* A page that idles above 8 % CPU gets a 3 s stack sample saved as `<report>.cpu-<page>.txt`.
* The measurement app has its own bundle id and no system extensions, so it cannot touch the installed ones. It cannot activate a tunnel,
  so its "connecting" state keeps the route animation running; read Home's CPU with that in mind.

## What it has found

* Adblock › Adblock test froze the window: environment closures compare as changed on every pass (fixed with `RouteAction`; `check-env-closures.py` guards it).
* Security Center idled at 13–20 %: the radar swept at 30 fps with nothing to find (now still when nothing was blocked, 15 fps otherwise).
* Panel drop shadows cost about 3.4 points of CPU on Home because SwiftUI blurs them on the CPU (removed).
* Settings › Connection logs drew all 500 events at once and ran at 96 % CPU (now 100 at a time).

## VPN + DNS test that may drop the network

`macos/tools/probe-vpn-dns.sh` connects VPN only, VPN + DNS, reconnects quickly, runs the control, quits the app, then restores protection to off.
It is meant to lose the network for a while: every probe is time-bounded, and the script restores protection on every exit path, including
Ctrl-C and a closed terminal (it traps INT, TERM, HUP and EXIT). It refuses to start unless protection is off, and stops if a system-extension
approval prompt is waiting. Evidence goes to `macos/test-evidence/probe-plan-<time>.txt`. It needs the installed, notarized build and the
VayuSetu app running, because it drives protection through `vayusetu://` links.
