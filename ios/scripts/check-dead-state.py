#!/usr/bin/env python3
"""Finds screens that can present a dialog or sheet which nothing ever asks for.

  python3 ios/scripts/check-dead-state.py

A SwiftUI view that presents with `isPresented: $flag` can only ever show it if something sets `flag` to true. When the button that did was removed and the flag
and the dialog stayed, the dialog is unreachable code that looks like a safety path (for example a confirmation before a destructive reset). This reads every
iPhone and Mac view, finds each `@State` flag that starts false and is used to present something, and fails if nothing in the same view sets it or binds it to a
control. Exit 0 when there are none, 1 when there are (each is listed)."""
import glob, re, sys
from pathlib import Path

ios = Path(__file__).resolve().parents[1]
files = sorted(glob.glob(str(ios / 'Sources/*.swift')) + glob.glob(str(ios.parent / 'macos/Sources/*.swift')))
decl_re = re.compile(r'^\s*(?:@\w+\s+)*struct\s+(\w+)[^{\n]*\{', re.M)
state_re = re.compile(r'@State\s+(?:private\s+)?var\s+(\w+)\s*(?::\s*[\w<>?\[\]]+)?\s*=\s*false[^\n]*')

def block(s, start):
    """The text of a struct, matching braces but not those inside string literals."""
    depth = 0; i = start; in_string = False
    while i < len(s):
        c = s[i]
        if c == '"' and s[i - 1] != '\\': in_string = not in_string
        elif not in_string:
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0: return s[start:i + 1]
        i += 1
    return s[start:]

dead, checked = [], 0
for f in files:
    s = open(f).read()
    for m in decl_re.finditer(s):
        b = block(s, m.end() - 1)
        for sm in state_re.finditer(b):
            n = sm.group(1); checked += 1
            rest = b[:sm.start()] + b[sm.end():]                      # the struct without that one declaration
            binds = re.findall(r'\$' + n + r'\b', rest)
            presenting = re.findall(r'(?:isPresented|isActive)\s*:\s*\$' + n + r'\b', rest)
            if not presenting or len(binds) > len(presenting): continue   # not a presenter, or something else (a control) can set it
            if re.search(r'(?<![\w.$])' + n + r'\s*=\s*\S', rest) or re.search(r'(?<![\w.$])' + n + r'\.toggle\(\)', rest): continue
            dead.append(f"{Path(f).name}: in {m.group(1)}, '{n}' presents something but nothing ever sets it, so it can never appear")
if dead:
    print('FAIL  unreachable dialogs:'); [print('  - ' + d) for d in dead]; sys.exit(1)
print(f'PASS  no unreachable dialogs among {checked} presentation flags')
