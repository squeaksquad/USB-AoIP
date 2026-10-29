#!/bin/bash
# check.sh LABEL RATE [SECONDS]: one Dante-side set (set-rate-one.py) with the Mac's nominal rate
# logged every 0.25 s (LABEL-mac-rate.txt), then the owner's and arbiter's journal lines and
# the arbiter's newest receipt (LABEL-pi.txt). For the rate-request battery, 2026-10-29.
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../../.." && pwd)
label=$1; rate=$2; seconds=${3:-40}; setrate=${SETRATE:?compiled setrate.swift}
( while :; do echo "$(date -u +%T.%N | cut -c1-12) $("$setrate" 'USB 16x16')"; sleep 0.25; done ) > "$here/$label-mac-rate.txt" 2>&1 &
poller=$!
echo "$(date -u +%T) $label set $rate" | tee -a "$here/steps.txt"
python3 "$repo/outputs/latency/rate44-live-20261028/set-rate-one.py" 169.254.92.97 "$rate"
sleep "$seconds"; kill $poller
awk '{r=$NF} r!=p{print; p=r}' "$here/$label-mac-rate.txt" | tee -a "$here/steps.txt"
ssh bdimaio@audio-dev.local "journalctl -u usb16x16-dante -u usb16x16-dante-rate --since '-$((seconds + 5))s' --utc -o short-iso | grep -E 'USBRATE|USBOPEN|USBCLOSE|Started usb16x16-dante.service|: done|refused' | cut -c1-260
f=\$(ls -t ~/usb-16x16-work/web-apply/receipts/*.json | head -1)
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(\"receipt\", r[\"state\"], r.get(\"rate\"), r.get(\"error\")); [print(\" \", s[\"at\"], s[\"name\"], s[\"ok\"], s[\"detail\"][:150]) for s in r[\"steps\"]]' \$f
echo history \$(tr -d '\n ' < ~/usb-16x16-work/web-apply/rate-history.json)" | tee "$here/$label-pi.txt"
