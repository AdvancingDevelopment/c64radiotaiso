#!/usr/bin/env python3
"""Print segment usage from the ACME symbol list (labels *_start/*_end)."""
import re, sys, os
sym = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"\s*(\w+)\s*=\s*\$([0-9a-fA-F]+)", line)
    if m:
        sym[m.group(1)] = int(m.group(2), 16)
size = os.path.getsize(sys.argv[2]) if len(sys.argv) > 2 else 0
segs = [("code", "code_start", "code_end", "CODE_LIMIT"),
        ("charset", "charset_start", "charset_end", "CHARSET_LIMIT"),
        ("frames", "frames_start", "frames_end", "FRAMES_LIMIT"),
        ("bankdata", "frames_end", "bankdata_end", "FRAMES_LIMIT"),
        ("data", "data_start", "data_end", "DATA_LIMIT")]
print(f"taiso.prg: {size} bytes")
for name, a, b, lim in segs:
    if a in sym and b in sym:
        used = sym[b] - sym[a]
        room = sym.get(lim, 0) - sym[a] if lim in sym else 0
        pct = f"{100*used/room:5.1f}%" if room else "  n/a"
        print(f"  {name:8s} ${sym[a]:04x}-${sym[b]-1:04x}  {used:6d} B  of {room:6d} ({pct})")
