#!/bin/bash
# dirtest.sh RATE TAG: while the Mac runs `continuous`, play 15 s of low-level noise
# to the Mac (gadget playback) and record 8 s of what the Mac sends (gadget capture).
R=$1; T=$2; d=/dev/shm/rate882; mkdir -p $d
python3 - $R $d/noise.raw <<PY
import os, sys
r = int(sys.argv[1]); n = r * 15 * 16
b = bytearray(os.urandom(n * 3))
table = bytes(0 if i < 128 else 255 for i in range(256))
b[2::3] = bytes(b[2::3]).translate(table)       # MSB = sign extension: |x| < 2^15, about -36 dBFS
open(sys.argv[2], "wb").write(b)
PY
sleep 4
aplay -q -D hw:UAC2Gadget -f S24_3LE -c 16 -r $R $d/noise.raw 2>$d/$T-aplay.err &
ap=$!
sleep 3
arecord -q -D hw:UAC2Gadget -f S24_3LE -c 16 -r $R -d 8 -t raw $d/$T-cap.raw 2>$d/$T-arecord.err
wait $ap
echo "aplay=$? $(cat $d/$T-aplay.err) arecord: $(cat $d/$T-arecord.err)"
python3 - $d/$T-cap.raw $R <<PY
import re, sys
b = open(sys.argv[1], "rb").read(); r = int(sys.argv[2]); fs = 48
frames = len(b) // fs
runs = [(m.start(), m.end() - m.start()) for m in re.finditer(rb"\x00{192,}", b)]
zf = sum(l // fs for _, l in runs)
lens = sorted(l // fs for _, l in runs)
print(f"mac->pi capture: {frames} frames ({frames / r:.2f} s), all-channel zero runs>=4: {len(runs)}, zero frames {100 * zf / max(frames, 1):.1f} %, run lengths min/median/max {lens[0] if lens else 0}/{lens[len(lens)//2] if lens else 0}/{lens[-1] if lens else 0}")
print("first runs (frame, len):", [(s // fs, l // fs) for s, l in runs[:8]])
PY
rm -f $d/noise.raw
