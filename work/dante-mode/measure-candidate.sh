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
#   measure-candidate.sh soak [SECONDS] [FRAMES] [LABEL]
#                                                    all-16 continuous load (the
#                                                    battery's soak): every channel
#                                                    must return signal with no zero
#                                                    run of 4 or more; default 600 s
# USB16X16_OTHER_LOAD=0.1 loads the other 15 channels in the impulse run.
# Close RTL Utility first: the harness and RTL never share the device.
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
mode=impulse
if [[ "${1:-}" == noise || "${1:-}" == soak ]]; then mode=$1; shift; fi
if [[ $mode == soak ]]; then
  soak_seconds=${1:-600}; frames=${2:-32}; label=${3:-dante}; impulses=0
else
  frames=${1:-32}
  if [[ $mode == noise ]]; then impulses=100; label=${2:-dante}; else impulses=${2:-800}; label=${3:-dante}; fi
fi
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
[[ $mode == soak ]] && stem="${label}-soak-${soak_seconds}s-${frames}f-${timestamp}"
result_path="$out_dir/${stem}.json"
api_dir="$out_dir/${stem}-api"
mkdir -p "$api_dir"

pi() { ssh -o BatchMode=yes -o ConnectTimeout=8 bdimaio@192.168.1.201 "$@"; }

# One line of gates, then the endpoint's own account of itself.
pi_state() {
  pi 'f=$(ls -t /dev/shm/dante-alsaloop-*.log /dev/shm/dante-owner-*.log 2>/dev/null | head -1)
# Under usb16x16-dante.service the endpoint logs to the journal: read this start of it from there.
if [ "$(systemctl is-active usb16x16-dante 2>/dev/null)" = active ]; then
  f=/dev/shm/dante-service-journal.txt
  journalctl -u usb16x16-dante --no-pager -o cat _SYSTEMD_INVOCATION_ID="$(systemctl show usb16x16-dante -p InvocationID --value)" > $f 2>/dev/null
fi
# A candidate started by the launcher runs as "owner" from its staged copy and logs to /dev/shm.
echo "aes67=$(systemctl is-active usb16x16-aes67) statime=$(pgrep -xc statime) endpoint=$(( $(pgrep -xc alsaloop) + $(pgrep -xc usb16x16-dante-) + $(systemctl is-active --quiet usb16x16-dante-candidate && echo 1 || echo 0) )) udc=$(cat /sys/class/udc/*/state 2>/dev/null)"
echo "log=$f"
[ -n "$f" ] && { grep -m1 "^START" "$f"; echo "xrun_lines=$(grep -ciE "xrun|underrun" "$f") lag_lines=$(grep -ciE "lag of|dropout|clock jumped|media clock" "$f") error_lines=$(grep -c " ERROR " "$f") lines=$(wc -l < "$f")"; }
for d in pcm0c pcm0p; do echo "$d $(grep -E "state|delay" /proc/asound/UAC2Gadget/$d/sub0/status 2>/dev/null | tr -s " " | tr "\n" " ")"; done
echo "pitch $(amixer -c UAC2Gadget cget numid=1 | tail -1 | tr -d " :") $(amixer -c UAC2Gadget cget numid=2 | tail -1 | tr -d " :")"'
}

print -r -- "=== measure Dante candidate ($mode): ${frames} frames, ${impulses} impulses${soak_seconds:+, ${soak_seconds} s} ($timestamp)"
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

if [[ $mode == soak ]]; then
  "$app_binary" continuous --device "USB 16x16" --buffer-frames "$frames" \
    --seconds "$soak_seconds" --other-channel-load-amplitude 0.1 --output "$result_path" \
    >/dev/null 2>"$api_dir/measure.log"
  measure_exit=$?
  print -r -- "measure_exit=$measure_exit result=$result_path"
  if (( measure_exit == 0 )) && [[ -s "$result_path" ]]; then
    # The battery's criteria (work/dsp-service/validate.py): full-length capture,
    # signal on every channel, no zero run of 4 or more, nothing non-finite or at full scale.
    /usr/bin/python3 - "$result_path" <<'PYEOF' || measure_exit=7
import json, sys
d = json.load(open(sys.argv[1])); bad = []
for key in ("inputDiscontinuities", "outputDiscontinuities"):
    if d.get(key): bad.append(f"{key}={d[key]}")
for i, c in enumerate(d["channels"], 1):
    why = []
    if c["samples"] < (d["seconds"] - 3) * 48000: why.append("short")
    if c["peak"] < 1e-8: why.append("silent")
    if c["longestZeroRun"] >= 4: why.append(f"zero run {c['longestZeroRun']}")
    if c.get("nonFinite"): why.append("non-finite")
    if c.get("fullScaleSamples"): why.append("full scale")
    if why: bad.append(f"ch{i}: " + ", ".join(why))
runs = [c["longestZeroRun"] for c in d["channels"]]
peaks = [c["peak"] for c in d["channels"]]
print(f"channels={len(d['channels'])} seconds={d['seconds']} longest zero run max={max(runs)} peak min={min(peaks):.4f} max={max(peaks):.4f}")
print(f"discontinuities in={d.get('inputDiscontinuities')} out={d.get('outputDiscontinuities')}")
print("soak: PASS" if not bad else "soak: FAIL " + "; ".join(bad))
raise SystemExit(1 if bad else 0)
PYEOF
  else
    print -r -- "harness stderr: $(head -c 300 "$api_dir/measure.log")"
  fi
elif [[ $mode == noise ]]; then
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
lo, hi, med = d.get('ioOffsetMinimumSamples'), d.get('ioOffsetMaximumSamples'), st.get('medianSamples')
if lo is not None and med is not None:
    # What RTL Utility and a DAW read: the device-timeline lag plus the IOProc's output-minus-input offset.
    steady = "steady" if lo == hi else f"VARIED {lo}..{hi}"
    print(f"daw_timeline={(med + lo) / 48:.3f} ms ({med + lo}) = {med} + io_offset {lo} ({steady})")
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
