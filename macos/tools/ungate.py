#!/usr/bin/env python3
"""Make an iOS-only block available on macOS: ungate.py FILE 'text on a line right after the #if' [keep-else]
Removes the matching `#if os(iOS)` / `#endif`. If the block has an `#else`, its else-branch is deleted (the iOS branch wins)."""
import re, sys
path, anchor = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
for i, l in enumerate(lines):
    if l.strip() == "#if os(iOS)" and any(anchor in x for x in lines[i+1:i+4]):
        depth, else_at, end = 0, None, None
        for j in range(i, len(lines)):
            s = lines[j].strip()
            if s.startswith("#if"): depth += 1
            elif s == "#else" and depth == 1: else_at = j
            elif s == "#endif":
                depth -= 1
                if depth == 0: end = j; break
        assert end, "no matching #endif"
        if else_at: del lines[else_at:end+1]
        else: del lines[end]
        del lines[i]
        open(path, "w").write("\n".join(lines)); print("ungated", path, "line", i+1, "else-removed" if else_at else ""); break
else: print("NOT FOUND", anchor); sys.exit(1)
