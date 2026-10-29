#!/bin/bash
# run.sh: the Mac-follow experiment's sequence (RATE_REPORT_PLAN.md, "Mac-follow
# experiment"), run from the Mac once test-rate-request.sh on the Pi says CANDIDATE READY.
# Logs, all in this directory: mac-rate.txt (the Mac's nominal rate every 0.5 s),
# mac-log.txt (AppleUSBAudio's own messages), pi-kernel.txt (the gadget's "rate request:"
# lines and USB events), steps.txt (what was done when). Ends with the Mac at 48000 and
# the test's end file touched on the Pi.
#   run.sh SETRATE HOLD     (the compiled setrate.swift and hold.swift)
set -u
here=$(cd "$(dirname "$0")" && pwd)
setrate=$1; hold=$2
pi=bdimaio@audio-dev.local
dev="USB 16x16"
gap=${GAP:-20}
stamp() { date -u +%H:%M:%S.%3N 2>/dev/null || date -u +%H:%M:%S; }
step() { echo "$(date -u +%T) $*" | tee -a "$here/steps.txt"; }
request() { ssh $pi "amixer -c UAC2Gadget cset iface=PCM,name='Device Rate Request' $1 >/dev/null && amixer -c UAC2Gadget cget iface=PCM,name='Capture Rate' | sed -n 's/^  : values=/capture rate /p'"; }

: > "$here/steps.txt"
( while :; do echo "$(date -u +%T) $("$setrate" "$dev")"; sleep 0.5; done ) > "$here/mac-rate.txt" 2>&1 &
poller=$!
log stream --style compact --predicate 'senderImagePath CONTAINS[c] "AppleUSBAudio" OR (process == "coreaudiod" AND eventMessage CONTAINS[c] "sample rate")' > "$here/mac-log.txt" 2>&1 &
maclog=$!
ssh $pi 'dmesg -w --time-format iso | grep --line-buffered -E "rate request|dwc2|UAC2|uac2"' > "$here/pi-kernel.txt" 2>&1 &
pilog=$!
trap 'kill $poller $maclog $pilog 2>/dev/null' EXIT
sleep 3

step "R0 Mac idle: $("$setrate" "$dev")"
step "R1 request 44100, Mac idle: $(request 44100)"; sleep "$gap"
step "R1 after ${gap}s: $("$setrate" "$dev")"
step "R2 request 48000, Mac idle: $(request 48000)"; sleep "$gap"
step "R2 after ${gap}s: $("$setrate" "$dev")"
step "R3 hold client open"; "$hold" "$dev" 32 >/dev/null 2>&1 & holdpid=$!; sleep 5
step "R3 request 44100, streaming: $(request 44100)"; sleep "$gap"
step "R3 after ${gap}s: $("$setrate" "$dev")"
step "R4 request 48000, streaming: $(request 48000)"; sleep "$gap"
step "R4 after ${gap}s: $("$setrate" "$dev")"
kill $holdpid 2>/dev/null; wait $holdpid 2>/dev/null; step "R4 hold client closed"; sleep 3

now=$("$setrate" "$dev")
case "$now" in *nominal=48000*) step "end: $now";; *) step "end: $now; setting 48000: $("$setrate" "$dev" 48000)";; esac
ssh $pi 'touch /dev/shm/rate-request-test.end'; step "end file touched"
sleep 2
