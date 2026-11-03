#!/usr/bin/env python3
"""Fails when an EnvironmentKey holds a bare closure.

  python3 ios/scripts/check-env-closures.py

SwiftUI cannot compare closures, so a closure stored in the environment counts as changed on every update, and every view that reads it is
rebuilt every time. On the Mac that made a screen pushed onto the Adblock page redraw without end and freeze the window (found by the screen
tour). Wrap the action in an Equatable type (RouteAction) instead. Exit 0 when none is found, 1 when any is (each is listed)."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
key = re.compile(r"EnvironmentKey\s*\{[^}]*defaultValue\s*:\s*\(?\s*\(")        # defaultValue: (() -> Void)?  or  ((…) -> …)
found = []
for d in ("ios/Sources", "macos/Sources", "Packages"):
    for path in sorted((root / d).rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if key.search(line) and "->" in line.split("defaultValue", 1)[1]:
                found.append((path.relative_to(root), number, line.strip()[:110]))
for p, n, text in found: print(f"{p}:{n}: environment value is a closure: {text}")
print(f"{len(found)} environment closure(s)")
sys.exit(1 if found else 0)
