#!/bin/zsh
# Measure the round trip against the running usb16x16-aes67.service with the
# Mac harness alone: no candidate wrapper, no stack restart. A bridge RECOVER
# during the run is counted and reported, not fatal, which is what the
# deployment does. Usage: measure-under-service.sh FRAMES IMPULSES [LABEL]
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
frames=${1:-64}
impulses=${2:-800}
label=${3:-service}
maximum_lag_ms=${USB16X16_MAX_LAG_MS:-200}
ready_max_spread=${USB16X16_READY_MAX_SPREAD_SAMPLES:-9}
required_probes=${USB16X16_REQUIRED_SIGNAL_PROBES:-3}
probe_attempts=${USB16X16_SIGNAL_PROBE_ATTEMPTS:-40}
app_binary="$repo_root/work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$repo_root/outputs/latency"
result_path="$out_dir/${label}-roundtrip-${frames}f-${timestamp}.json"
api_dir="$out_dir/${label}-roundtrip-${frames}f-${timestamp}-api"
mkdir -p "$api_dir"

pi() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 "$@" 2>/dev/null ||
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@169.254.92.97 "$@"
}

print -r -- "=== measure under service: ${frames} frames, ${impulses} impulses ($timestamp)"
state=$(pi 'echo "$(systemctl is-active usb16x16-aes67) $(cut -d" " -f2- /run/usb16x16/stage 2>/dev/null | cut -c1-20) $(cut -d. -f1 /proc/uptime) $(wc -l < /run/usb16x16/recovers 2>/dev/null) $(grep -o "tx_restarts=[0-9]* rx_restarts=[0-9]*" /run/usb16x16/last-bridge 2>/dev/null)"')
print -r -- "service before: $state"
if [[ "${state%% *}" != active ]] || [[ "$state" != *" running "* ]]; then
  print -r -- "service is not running; refusing"
  print -r -- "exit=2"
  exit 2
fi
start_uptime=$(print -r -- "$state" | awk '{print $3}')
recovers_before=$(print -r -- "$state" | awk '{print $4}')

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

"$app_binary" measure --device "USB 16x16" --buffer-frames "$frames" \
  --input-channel 1 --output-channel 1 --impulses "$impulses" \
  --maximum-lag-ms "$maximum_lag_ms" --output "$result_path" \
  >/dev/null 2>"$api_dir/measure.log"
measure_exit=$?
print -r -- "measure_exit=$measure_exit result=$result_path"
if (( measure_exit == 0 )) && [[ -s "$result_path" ]]; then
  /usr/bin/python3 - "$result_path" <<'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1])); c = d["correlation"]
per = c.get("perImpulseDelaySamples") or []
levels = collections.Counter(per).most_common(4)
print(f"median={c.get('medianMilliseconds'):.3f} ms ({c.get('medianSamples')}) min={c.get('minimumSamples')} max={c.get('maximumSamples')} spread={c.get('maximumSamples')-c.get('minimumSamples')} score={c.get('score'):.3f} count={c.get('count')}")
print("levels=" + " ".join(f"{s}x{n}" for s, n in levels))
print(f"discontinuities in={d.get('inputDiscontinuities')} out={d.get('outputDiscontinuities')}")
PYEOF
else
  print -r -- "harness stderr: $(head -c 300 "$api_dir/measure.log")"
fi

after=$(pi 'echo "$(systemctl is-active usb16x16-aes67) $(cut -d. -f1 /proc/uptime) $(wc -l < /run/usb16x16/recovers 2>/dev/null) nrestarts=$(systemctl show -p NRestarts --value usb16x16-aes67) $(grep -o "tx_restarts=[0-9]* rx_restarts=[0-9]*\|tx_qfloor=[0-9]* rx_qfloor=[0-9]*\|tx_pullmax=[0-9]*\|tx_gapmax_us=[0-9]* rx_gapmax_us=[0-9]*" /run/usb16x16/last-bridge 2>/dev/null | paste -sd" ")"')
print -r -- "service after: $after"
recovers_after=$(print -r -- "$after" | awk '{print $3}')
print -r -- "recovers during run: $(( ${recovers_after:-0} - ${recovers_before:-0} ))"
pi "journalctl -b --no-pager -o short-monotonic -t usb16x16-aes67 | grep -E 'RECOVER|FAIL' | awk -F'[][]' -v s=$start_uptime '\$2+0 > s' | cut -c1-200" | sed 's/^/  /'
print -r -- ""
print -r -- "exit=$measure_exit"
