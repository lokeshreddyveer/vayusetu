#!/usr/bin/env python3
"""Fails when a diagnostic or test launch argument is read outside `#if DEBUG` in the app sources.

  python3 ios/scripts/check-debug-hooks.py

The apps accept launch arguments such as --ui-testing, --privacy-check or --page so tests and diagnostics can drive them. In a release build those
would be switches anyone could use, so every one has to sit in a debug-only region. This reads the sources rather than the binary, because Swift
stores short string literals inline and `strings` cannot find them. Exit 0 when every use is debug-only, 1 when not (each is listed)."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
flag = re.compile(r'"--[a-z][a-z0-9-]*"')
allowed = {'"--dns"'}          # arguments passed to system tools, not read from our own launch
found = []
for d in ("ios/Sources", "ios/Tunnel", "macos/Sources", "macos/Filter", "macos/Tunnel"):
    for path in sorted((root / d).rglob("*.swift")):
        stack = []              # one entry per open #if: True while inside a DEBUG-only branch
        for number, line in enumerate(path.read_text().splitlines(), 1):
            t = line.strip()
            if t.startswith("#if"): stack.append(bool(re.search(r"\bDEBUG\b", t)) and "!" not in t.split("DEBUG")[0])
            elif t.startswith("#else") and stack: stack[-1] = False
            elif t.startswith("#endif") and stack: stack.pop()
            code = line.split("//")[0]
            if "arguments" not in code and "args" not in code: continue
            for m in flag.findall(code):
                if m in allowed or any(stack): continue
                found.append((path.relative_to(root), number, m))
for p, n, m in found: print(f"{p}:{n}: launch argument {m} is read in release builds")
print(f"{len(found)} launch argument(s) outside #if DEBUG")
sys.exit(1 if found else 0)
