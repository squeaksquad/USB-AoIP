#!/usr/bin/env python3
"""count-chanholes.py OWNER_LOG: CHANHOLE events (lines within 2 ms are one event) inside the soak's
continuous load, i.e. after the last USBLINK going to tx=flow rx=flow and before the next USBLINK
(2026-10-31, rate96-en7). Prints each event's channels and lengths and a summary by shape."""
import re, sys, time, collections
lines = open(sys.argv[1], errors="replace").read().splitlines()
flows = [i for i, l in enumerate(lines) if l.startswith("USBLINK") and "tx=flow rx=flow" in l]
start = flows[-1]
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("USBLINK")), len(lines))
holes = [dict(re.findall(r"(\w+)=(\S+)", l)) for l in lines[start:end] if l.startswith("CHANHOLE")]
events, cur = [], []
for h in holes:
    if cur and float(h["wall"]) - float(cur[-1]["wall"]) > 0.002:
        events.append(cur); cur = []
    cur.append(h)
if cur: events.append(cur)
shapes = collections.Counter()
for e in events:
    ch = sorted({int(h["ch"]) for h in e}); fr = sorted({int(h["frames"]) for h in e})
    t = time.strftime("%H:%M:%S", time.gmtime(float(e[0]["wall"])))
    print(f"{t} {e[0]['point']} ch={','.join(map(str, ch))} frames={','.join(map(str, fr))}")
    key = ("all8" if len(ch) == 8 else "ch4-only<=11" if ch == [4] and max(fr) <= 11 else "other")
    shapes[key] += 1
first = time.strftime("%H:%M:%S", time.gmtime(float(holes[0]["wall"]))) if holes else "-"
print(f"window lines {start}..{end}; CHANHOLE lines {len(holes)}; events {len(events)}; first {first}; by shape {dict(shapes)}")
