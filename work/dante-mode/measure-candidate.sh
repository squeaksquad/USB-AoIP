#!/bin/zsh
# Measure the USB round trip through the Dante endpoint with the Mac harness.
# The Dante counterpart of work/aes67-candidate/measure-under-service.sh: same
# harness, same signal gating (three consecutive 8-impulse probes agreeing
# before the main run), but the Pi-side checks are for the Dante stack: the
# AES67 service stopped, Statime running, an endpoint process running, and the
# endpoint's log read before and after for xruns and Inferno errors.
#
#   measure-candidate.sh FRAMES IMPULSES [LABEL]     impulse run on channel 1
#   measure-candidate.sh noise FRAMES [LABEL]        hole probe: out 1 / in 2, 0.1
#                                                    load on the other channels,
#                                                    capture analysed by zeros.py
# USB16X16_OTHER_LOAD=0.1 loads the other 15 channels in the impulse run.
# Close RTL Utility first: the harness and RTL never share the device.
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
mode=impulse
if [[ "${1:-}" == noise ]]; then mode=noise; shift; fi
frames=${1:-32}
if [[ $mode == noise ]]; then impulses=100; label=${2:-dante}; else impulses=${2:-800}; label=${3:-dante}; fi
maximum_lag_ms=${USB16X16_MAX_LAG_MS:-200}
ready_max_spread=${USB16X16_READY_MAX_SPREAD_SAMPLES:-9}
required_probes=${USB16X16_REQUIRED_SIGNAL_PROBES:-3}
probe_attempts=${USB16X16_SIGNAL_PROBE_ATTEMPTS:-40}
other_load=${USB16X16_OTHER_LOAD:-}
load_args=()
if [[ -n "$other_load" ]]; then load_args=(--other-channel-load-amplitude "$other_load"); fi
app_binary="$repo_root/work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
zeros_py="$repo_root/outputs/latency/usb-holes-20260904/zeros.py"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$repo_root/outputs/latency"
stem="${label}-roundtrip-${frames}f-${timestamp}"
[[ $mode == noise ]] && stem="${label}-noise-ch2-${frames}f-${timestamp}"
result_path="$out_dir/${stem}.json"
api_dir="$out_dir/${stem}-api"
mkdir -p "$api_dir"

pi() { ssh -o BatchMode=yes -o ConnectTimeout=8 bdimaio@192.168.1.201 "$@"; }

# One line of gates, then the endpoint's own account of itself.
pi_state() {
  pi 'f=$(ls -t /dev/shm/dante-alsaloop-*.log 2>/dev/null | head -1)
echo "aes67=$(systemctl is-active usb16x16-aes67) statime=$(pgrep -xc statime) endpoint=$(pgrep -xc alsaloop) udc=$(cat /sys/class/udc/*/state 2>/dev/null)"
echo "log=$f"
[ -n "$f" ] && { grep -m1 "^START" "$f"; echo "xrun_lines=$(grep -ciE "xrun|underrun" "$f") lag_lines=$(grep -ciE "lag of|dropout|clock jumped|media clock" "$f") error_lines=$(grep -c " ERROR " "$f") lines=$(wc -l < "$f")"; }
for d in pcm0c pcm0p; do echo "$d $(grep -E "state|delay" /proc/asound/UAC2Gadget/$d/sub0/status 2>/dev/null | tr -s " " | tr "\n" " ")"; done
echo "pitch $(amixer -c UAC2Gadget cget numid=1 | tail -1 | tr -d " :") $(amixer -c UAC2Gadget cget numid=2 | tail -1 | tr -d " :")"'
}

print -r -- "=== measure Dante candidate ($mode): ${frames} frames, ${impulses} impulses ($timestamp)"
before=$(pi_state)
print -r -- "$before" | tee "$api_dir/pi-before.txt" | sed 's/^/  before: /'
gates=${before%%$'\n'*}
if [[ "$gates" != *"aes67=inactive"* || "$gates" == *"statime=0"* || "$gates" == *"endpoint=0"* ]]; then
  print -r -- "Dante stack is not up (need AES67 stopped, Statime and the endpoint running); refusing"
  print -r -- "exit=2"
  exit 2
fi
if ! "$app_binary" inspect --device "USB 16x16" >/dev/null 2>&1; then
  print -r -- "CoreAudio does not expose USB 16x16; refusing"
  print -r -- "exit=3"
  exit 3
fi

consecutive=0
signal_ready=
for attempt in $(seq 1 "$probe_attempts"); do
  probe_path="$api_dir/readiness-probe-${attempt}.json"
  if "$app_binary" measure --device "USB 16x16" --buffer-frames "$frames" \
       --input-channel 1 --output-channel 1 --impulses 8 \
       --maximum-lag-ms "$maximum_lag_ms" --output "$probe_path" \
       >/dev/null 2>"$api_dir/readiness-probe-${attempt}.log" &&
     USB16X16_PROBE="$probe_path" USB16X16_MAX_SPREAD="$ready_max_spread" /usr/bin/python3 - <<'PYEOF'
import json, os
probe = json.load(open(os.environ["USB16X16_PROBE"]))
delays = probe["correlation"]["perImpulseDelaySamples"]
peak = float(probe["capturedPeak"])
raise SystemExit(0 if peak >= 0.01 and max(delays) - min(delays) <= int(os.environ["USB16X16_MAX_SPREAD"]) else 1)
PYEOF
  then
    (( consecutive += 1 ))
    print -r -- "probe $attempt PASS consecutive=$consecutive" >> "$api_dir/settle.log"
  else
    consecutive=0
    print -r -- "probe $attempt FAIL consecutive=0 $(head -c 120 "$api_dir/readiness-probe-${attempt}.log" 2>/dev/null)" >> "$api_dir/settle.log"
  fi
  if (( consecutive >= required_probes )); then
    signal_ready=1
    print -r -- "return signal ready after $attempt probes"
    break
  fi
  sleep 1
done
if [[ -z "$signal_ready" ]]; then
  print -r -- "return signal never passed $required_probes consecutive probes"
  tail -5 "$api_dir/settle.log"
  print -r -- "exit=6"
  exit 6
fi

if [[ $mode == noise ]]; then
  raw="$api_dir/capture.raw"
  USB16X16_DUMP="$raw" "$app_binary" measure --device "USB 16x16" --buffer-frames "$frames" \
    --output-channel 1 --input-channel 2 --other-channel-load-amplitude 0.1 \
    --impulses "$impulses" --maximum-lag-ms "$maximum_lag_ms" --output "$result_path" \
    >/dev/null 2>"$api_dir/measure.log"
  measure_exit=$?
  print -r -- "measure_exit=$measure_exit result=$result_path"
  if [[ -s "$raw" ]]; then
    /usr/bin/python3 "$zeros_py" "$raw" "$frames" | tee "$api_dir/zeros.txt"
    rm -f "$raw" "$raw.markers"     # several MB of floats; the analysis is what is kept
  else
    print -r -- "no capture dump; harness stderr: $(head -c 300 "$api_dir/measure.log")"
  fi
else
  "$app_binary" measure --device "USB 16x16" --buffer-frames "$frames" \
    --input-channel 1 --output-channel 1 --impulses "$impulses" "${load_args[@]}" \
    --maximum-lag-ms "$maximum_lag_ms" --output "$result_path" \
    >/dev/null 2>"$api_dir/measure.log"
  measure_exit=$?
  print -r -- "measure_exit=$measure_exit result=$result_path"
  if (( measure_exit == 0 )) && [[ -s "$result_path" ]]; then
    /usr/bin/python3 - "$result_path" <<'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1])); c = d["correlation"]; st = c.get("statistics", {})
per = c.get("perImpulseDelaySamples") or []
levels = collections.Counter(per).most_common(4)
print(f"median={st.get('medianMilliseconds', 0):.3f} ms ({st.get('medianSamples')}) min={st.get('minimumSamples')} max={st.get('maximumSamples')} spread={(st.get('maximumSamples') or 0)-(st.get('minimumSamples') or 0)} score={c.get('score', 0):.3f} count={st.get('count')}")
print("levels=" + " ".join(f"{s}x{n}" for s, n in levels))
print(f"discontinuities in={d.get('inputDiscontinuities')} out={d.get('outputDiscontinuities')}")
PYEOF
  else
    print -r -- "harness stderr: $(head -c 300 "$api_dir/measure.log")"
  fi
fi

after=$(pi_state)
print -r -- "$after" | tee "$api_dir/pi-after.txt" | sed 's/^/  after: /'
count() { print -r -- "$1" | grep -o "$2=[0-9]*" | head -1 | cut -d= -f2; }
print -r -- "during run: xrun lines +$(( $(count "$after" xrun_lines) - $(count "$before" xrun_lines) )), lag lines +$(( $(count "$after" lag_lines) - $(count "$before" lag_lines) )), error lines +$(( $(count "$after" error_lines) - $(count "$before" error_lines) ))"
print -r -- ""
print -r -- "exit=$measure_exit"
