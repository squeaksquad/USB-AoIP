#!/usr/bin/env python3
"""count-chanholes-window.py OWNER_LOG FROM_EPOCH TO_EPOCH: CHANHOLE events (lines within 2 ms are one
event) by wall time, plus playback_faults at the window's ends (2026-10-31, rate96-en7: the morning's
log re-links at each fault, so count-chanholes.py's last-link window is only its last stretch)."""
import re, sys, time, collections
lo, hi = float(sys.argv[2]), float(sys.argv[3])
holes, events, cur = [], [], []
for l in open(sys.argv[1], errors="replace"):
    if l.startswith("CHANHOLE"):
        h = dict(re.findall(r"(\w+)=(\S+)", l))
        if lo <= float(h["wall"]) <= hi: holes.append(h)
for h in holes:
    if cur and float(h["wall"]) - float(cur[-1]["wall"]) > 0.002: events.append(cur); cur = []
    cur.append(h)
if cur: events.append(cur)
shapes = collections.Counter()
for e in events:
    ch = sorted({int(h["ch"]) for h in e}); fr = sorted({int(h["frames"]) for h in e})
    print(time.strftime("%H:%M:%S", time.gmtime(float(e[0]["wall"]))), e[0]["point"], "ch=" + ",".join(map(str, ch)), "frames=" + ",".join(map(str, fr)))
    shapes["all8" if len(ch) == 8 else "subset"] += 1
print(f"CHANHOLE lines {len(holes)}; events {len(events)}; by shape {dict(shapes)}")
