#!/bin/zsh
# dirtest-mac.sh RATE TAG: Mac half of the direction test (Pi half: ~/usb-16x16-work/rate882/dirtest.sh).
R=$1; T=$2; SP=${0:A:h}; cd "/Users/bryandimaio/Development/USB 16x16"
out=outputs/latency/rate882-dirtest-20261018/$T; mkdir -p ${out:h}
$SP/setrate/setrate "USB 16x16" $R
"work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency" continuous --device "USB 16x16" \
  --buffer-frames 32 --seconds 25 --other-channel-load-amplitude 0.1 --output $out.json 2>$out.log &
h=$!
sleep 1
ssh -o BatchMode=yes bdimaio@192.168.1.201 "~/usb-16x16-work/rate882/dirtest.sh $R $T" | tee $out.pi.txt
wait $h; print "harness exit=$?"
python3 - $out.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d["eventCapture"]; r = d["sampleRate"]
ev = e["events"]
print(f"pi->mac at {r}: triggered {e['triggeredEvents']} zero events (all channels, after the 2 s warmup), shown {len(ev)}, breaks {e['continuityBreaks']}, disc in/out {d['inputDiscontinuities']}/{d['outputDiscontinuities']}")
for x in ev[:40]:
    if x["channel"] == 1: print(f"  ch1 at {x['startInputFrame'] / r:7.3f} s  {x['zeroFrames']} frames  {x['termination']}")
print("peaks", sorted({round(c['peak'], 4) for c in d['channels']}))
PY
