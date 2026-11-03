#!/usr/bin/env python3
"""Runs the Mac app's screen tour and judges the result.

  macos/tools/perf-tour.py run [--pages "Home,Settings"] [--out FILE]   build nothing; run build/perf-app/VayuSetuPerf.app and save a report
  macos/tools/perf-tour.py check FILE                                  judge a saved report against the limits below (exit 1 on any failure)
  macos/tools/perf-tour.py show FILE                                   print every step

The tour (macos/Sources/PerfTour.swift, debug builds only) opens every page and every tab and drill-down screen it can reach, waits, scrolls
top to bottom and back, and records per step: frames drawn, frame-time percentiles, hitches (a frame later than 1.5 times the normal gap),
dropped frames, and the app's CPU share. It presses only navigation. Build the measurement app first with macos/tools/build-perf.sh.

Limits (a step breaks one when it is slower than this):
  scroll / tab / push / pop / enter steps  p99 frame gap <= 2.2 x the normal gap, worst gap <= 6 x, dropped frames <= 4 % of frames
  idle steps                               CPU <= 6 % of one core on a static page; no frame gap longer than 8 x the normal one
Pages that draw continuously on purpose (the connected scene) are not exempt: if one needs more, raise its limit here with a reason."""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "build", "perf-app", "VayuSetuPerf.app")
MOTION = {"scroll", "tab", "push", "pop", "enter"}
IDLE_CPU = 6.0
# page -> reason -> idle CPU limit, for pages that animate by design
IDLE_EXEMPT = {}

def run(args):
    out = args.out or os.path.join(HERE, "..", "test-evidence", f"perf-tour-{time.strftime('%Y%m%d-%H%M%S')}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = [os.path.join(APP, "Contents", "MacOS", "VayuSetu"), "--perf-tour", out]
    if args.pages: cmd += ["--perf-pages", args.pages]
    print("running:", " ".join(cmd))
    proc = subprocess.run(cmd, timeout=args.timeout)
    if not os.path.exists(out): print("no report written (exit %s)" % proc.returncode); return 2
    print("report:", out)
    return check_file(out)

def judge(step, hz_gap):
    problems = []
    if step["frames"] < 5: return [f"only {step['frames']} frames drawn"]
    base = step["p50"] or hz_gap
    if step["kind"] in MOTION:
        if step["p99"] > base * 2.2 + 1.0: problems.append(f"p99 frame gap {step['p99']:.1f} ms (normal {base:.1f})")
        if step["worst"] > base * 6: problems.append(f"worst frame gap {step['worst']:.1f} ms")
        if step["dropped"] > step["frames"] * 0.04: problems.append(f"{step['dropped']} dropped of {step['frames']} frames")
    else:
        limit = IDLE_EXEMPT.get(step["path"].split(" › ")[0], IDLE_CPU)
        if step["cpu"] > limit: problems.append(f"idle CPU {step['cpu']:.1f} % (limit {limit:.0f} %)")
        if step["worst"] > base * 8: problems.append(f"idle frame gap {step['worst']:.1f} ms")
    return problems

def check_file(path):
    report = json.load(open(path)); steps = report["steps"]
    gap = 1000.0 / (report.get("refreshHz") or 60)
    bad = 0
    for s in steps:
        for p in judge(s, gap):
            bad += 1; print(f"FAIL {s['kind']:6} {s['path']}: {p}")
    pages = sorted({s["path"].split(" › ")[0] for s in steps})
    idle = [s for s in steps if s["kind"] == "idle"]
    print(f"{len(steps)} steps over {len(pages)} pages ({len([s for s in steps if s['kind'] in ('tab','push')])} nested screens), "
          f"{bad} problem(s); busiest idle: " + (max(idle, key=lambda s: s['cpu'])['path'] + f" {max(s['cpu'] for s in idle):.1f} %" if idle else "none"))
    return 1 if bad else 0

def show(path):
    for s in json.load(open(path))["steps"]:
        print(f"{s['kind']:6} {s['path'][:56]:56} fps {s['fps']:5.1f}  p50 {s['p50']:5.1f}  p99 {s['p99']:6.1f}  worst {s['worst']:6.1f}  hitch {s['hitches']:3}  drop {s['dropped']:3}  cpu {s['cpu']:5.1f}%  mem {s['memoryMB']:.0f} MB")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run"); r.add_argument("--pages"); r.add_argument("--out"); r.add_argument("--timeout", type=int, default=900)
    c = sub.add_parser("check"); c.add_argument("file")
    s = sub.add_parser("show"); s.add_argument("file")
    a = ap.parse_args()
    sys.exit(run(a) if a.cmd == "run" else check_file(a.file) if a.cmd == "check" else show(a.file) or 0)
