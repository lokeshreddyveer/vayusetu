#!/usr/bin/env python3
"""Fails on force operations that data can reach: try!, as!, .first!/.last!, baseAddress!, [..]! lookups and URL(string:) built from non-literal text.

  python3 ios/scripts/check-unwraps.py

A crash in the tunnel or the filter drops the user's protection, so anything that depends on input, a lookup or a system call must handle the missing
case. Allowed: URL(string: "literal")! (a fixed, reviewed address), UUID(uuidString: "literal")!, and `WKNavigation!` style declarations. Tests are not
scanned. Exit 0 when clean, 1 when not (each is listed)."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
dirs = ["ios/Sources", "ios/Tunnel", "macos/Sources", "macos/Filter", "Packages/VayuSetuCore/Sources"]
rules = [
    (re.compile(r"\btry!"), "try!"),
    (re.compile(r"\bas!"), "as!"),
    (re.compile(r"\.(first|last|min|max)!"), ".first!/.last!/.min!/.max!"),
    (re.compile(r"baseAddress!"), "baseAddress!"),
    (re.compile(r"\w\]!"), "subscript lookup force-unwrapped"),
    (re.compile(r"\.value!"), ".value!"),
]
literal_url = re.compile(r'URL\(string:\s*"[^"\\]*"\)!')
any_url = re.compile(r"URL\(string:")
found = []
for d in dirs:
    for path in sorted((root / d).rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("//")[0]
            if "WKNavigation!" in code: continue
            for pattern, label in rules:
                if pattern.search(code): found.append((path.relative_to(root), number, label))
            for m in any_url.finditer(code):
                tail = code[m.start():]
                if re.match(r"URL\(string:[^()]*(\([^()]*\)[^()]*)*\)!", tail) and not literal_url.match(tail):
                    found.append((path.relative_to(root), number, "URL(string:) built from non-literal text and force-unwrapped"))
for p, n, label in found: print(f"{p}:{n}: {label}")
print(f"{len(found)} unsafe force operation(s)")
sys.exit(1 if found else 0)
