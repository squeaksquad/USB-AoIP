#!/bin/zsh
# Fetch a finished AoIP loop candidate from the Pi and read it.
#
# Runs on the Mac after run-aoip-candidate-safe.sh has printed DONE (never
# during a run: a transfer off the Pi mid-run has stalled the bridge). Copies
# ~/usb-16x16-work/logs/<DIR> into outputs/latency/<DIR>, then:
#
#   rtp-impulses.py --loop           the wire figure: AoIP in -> AoIP out at
#                                    the Pi's port, wall time and media-clock
#                                    samples, plus the Ferrofish wire loop
#   ... --bridge-log --mono-offset   the bridge's own dwell and the two
#                                    driver legs, from the IMPULSE lines
#   the SUMMARY line's stage cost, floors and restarts
#
# Usage: analyze-aoip-loop.sh phase4-aoip-candidate-<UTC>
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
pi=${USB16X16_PI:-audio-dev.local}
name=${1:?result directory name, e.g. phase4-aoip-candidate-20260912T120000Z}
local_dir="$repo_root/outputs/latency/$name"
tool="$repo_root/outputs/latency/stage-trace-20260906/rtp-impulses.py"

if ssh "$pi" 'pgrep -f "run-aoip-candidate-safe.sh" >/dev/null'; then
  print -r -- "the loop candidate is still running on the Pi; fetch after DONE" >&2
  exit 1
fi
mkdir -p "$local_dir"
rsync -a --info=progress2 "$pi:usb-16x16-work/logs/$name/" "$local_dir/" || exit 2
print -r -- "--- $local_dir"
cat "$local_dir/metadata.txt"
print -r -- "--- bridge lines of note"
grep -E '^(NEGOTIATED|ALIGN status|DSP loaded|DSP engaged|LOOPIMPULSE|PRIMED|RECOVER|METERS enabled)' "$local_dir/bridge.log" | head -20
print -r -- "--- SUMMARY"
if [ -s "$local_dir/summary.json" ]; then
  python3 - "$local_dir/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
keys = ["mode", "loop_impulses", "dsp_preset", "dsp_biquads", "dsp_us_max", "dsp_us_mean", "meter_us_max",
        "tx_restarts", "tx_queue_floor", "tx_depth_floor", "tx_queue_below_period", "tx_clipped_samples",
        "tx_dropped_frames", "align_ok", "align_tx_triggers", "align_tx_unaligned_triggers",
        "align_tx_front_age_frames", "impulse_ravenna_capture", "impulse_ravenna_playback",
        "zero_ravenna_capture", "zero_ravenna_playback"]
for k in keys:
    if k in s:
        print(f"  {k} = {s[k]}")
PY
fi
capture=$(grep '^capture_file=' "$local_dir/metadata.txt" | cut -d= -f2)
offset=$(grep '^mono_offset=' "$local_dir/metadata.txt" | cut -d= -f2)
if [ -n "$capture" ] && [ -s "$local_dir/$capture" ]; then
  print -r -- "--- wire instrument"
  python3 "$tool" "$local_dir/$capture" --loop --bridge-log "$local_dir/bridge.log" --mono-offset "$offset"
else
  print -r -- "no capture in the result directory (tcpdump.log follows)"
  cat "$local_dir/tcpdump.log" 2>/dev/null
fi
