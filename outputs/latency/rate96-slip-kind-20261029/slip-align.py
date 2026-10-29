#!/usr/bin/env python3
# slip-align.py BITEXACT.json OWNER.log [PI_MINUS_MAC_SECONDS]: each lost lock in a bitexact
# report (grouped across channels by frame), its kind, its Mac wall time, and the owner's
# --event-trace EVENT lines within 1 s of it (Pi wall clock moved by the offset), with the
# SERVO line before it. With --seq-check, the owner's SEQ lines are among those events. 2026-10-29, for the 96 kHz single-frame slips (RATE96_PLAN.md).
import json, re, sys
report = json.load(open(sys.argv[1]))
offset = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
rate, start = report["sampleRate"], report["inputStartUnixTime"]
loop = report.get("loopChannels", 16)
groups = {}
for number, channel in enumerate(report["channels"][:loop], 1):
    for slip in channel.get("slips", []):
        groups.setdefault(slip["frame"], []).append((number, slip["kind"], slip["count"]))
events, servos = [], []
for line in open(sys.argv[2], errors="replace"):
    m = re.match(r"SEQ n=\d+ wall=([\d.]+) (.*)", line)
    if m:
        events.append((float(m[1]) - offset, "SEQ " + m[2].strip()))
        continue
    m = re.match(r"(EVENT|SERVO) wall=([\d.]+) (.*)", line)
    if m:
        (events if m[1] == "EVENT" else servos).append((float(m[2]) - offset, m[3].strip()))
kinds = {}
print(f"rate {rate}, {report['seconds']} s, loop {loop}, pass {report['pass']}, {len(groups)} slip frames")
for frame in sorted(groups):
    rows = groups[frame]
    at = start + frame / rate
    names = sorted({f"{k} {c}" for _, k, c in rows})
    for name in names: kinds[name] = kinds.get(name, 0) + 1
    print(f"\nframe {frame} ({frame / rate:.3f} s into the run): channels {[n for n, _, _ in rows]}: {', '.join(names)}")
    for when, text in events:
        if abs(when - at) <= 1.0: print(f"   EVENT {when - at:+.3f} s  {text}")
    before = [s for s in servos if s[0] <= at]
    if before: print(f"   SERVO {before[-1][0] - at:+.3f} s  {before[-1][1]}")
print("\nkinds:", kinds)
