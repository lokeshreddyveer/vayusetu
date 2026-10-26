#!/usr/bin/env python3
"""Fails on animation that never stops: `repeatForever`, and a continuously redrawing TimelineView that cannot pause.

  python3 ios/scripts/check-animations.py

An animation that repeats forever (or a frame-rate TimelineView with no pause condition) redraws for as long as its window is open, even with nobody
looking, and held the Mac at about a third of a core while idle. Scenes go through SceneTimeline (macos/Sources/SceneDraw.swift), which stops when the
window is behind, the Mac is left alone, or the scene has nothing to show; a marker pulses a bounded number of times. Exit 0 when clean, 1 when not."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
found = []
for d in ("ios/Sources", "macos/Sources"):
    for path in sorted((root / d).rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("//")[0]
            rel = path.relative_to(root)
            if "repeatForever" in code: found.append((rel, number, "repeatForever never stops; use repeatCount(n) and let it rest"))
            if re.search(r"TimelineView\(\s*\.animation", code) and "paused:" not in code: found.append((rel, number, "frame-rate TimelineView without a paused: condition"))
for p, n, why in found: print(f"{p}:{n}: {why}")
print(f"{len(found)} animation(s) that cannot stop")
sys.exit(1 if found else 0)
