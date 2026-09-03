#!/bin/zsh
# Within-session latency measurements against one Phase 4 candidate while the
# split pitch servo moves the bridge's depth. Modelled on
# sweep-phase4-sink-delay.sh: one candidate, several harness measurements,
# each tagged with the bridge's depth at that moment, so the run-to-run
# start-alignment lottery (1227-1311 samples at the period-48 point) is held
# fixed and only the depth varies.
#
# Usage:
#   USB16X16_PHASE4_TX_DEPTH_FRAMES=336 USB16X16_PHASE4_RX_DEPTH_FRAMES=276 \
#     sweep-phase4-depth.sh 120 480 840
# The arguments are bridge seconds at which to measure (the first should be
# after readiness, about 100 s). The candidate runs USB16X16_CANDIDATE_SECONDS
# (default 1200, the wrapper's maximum). Point arguments default to the
# period-48 servo point with mode 2.
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
harness_dir="$repo_root/work/latency-harness"
app_binary="$harness_dir/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
pi_target=${USB16X16_PI_TARGET:-bdimaio@192.168.1.201}
ssh_options=(-o BatchMode=yes -o HostKeyAlias=audio-dev.local -o ConnectTimeout=8)
candidate_seconds=${USB16X16_CANDIDATE_SECONDS:-1200}
impulses=${USB16X16_SWEEP_IMPULSES:-200}
max_spread=${USB16X16_READY_MAX_SPREAD_SAMPLES:-9}
remote_ready_file=/tmp/usb16x16-phase4-candidate.ready
remote_arguments="$candidate_seconds ${USB16X16_PHASE4_PERIOD_FRAMES:-48} ${USB16X16_PHASE4_BUFFER_FRAMES:-192} ${USB16X16_PHASE4_RING_FRAMES:-768} ${USB16X16_PHASE4_TARGET_FRAMES:-128} ${USB16X16_PHASE4_PLAYBACK_PRIME_FRAMES:-96} ${USB16X16_PHASE4_PRIME_TRIM:-0} ${USB16X16_PHASE4_TX_PLAYBACK_PRIME_FRAMES:-288} ${USB16X16_PHASE4_RX_PLAYBACK_PRIME_FRAMES:-144} ${USB16X16_PHASE4_RAVENNA_PLAYBACK_BUFFER_FRAMES:-384} ${USB16X16_PHASE4_SINK_DELAY:-576} ${USB16X16_PHASE4_USB_PITCH_SERVO:-2} ${USB16X16_PHASE4_TX_DEPTH_FRAMES:-0} ${USB16X16_PHASE4_RX_DEPTH_FRAMES:-0} ${USB16X16_PHASE4_LEVEL_GAIN:-0.05} ${USB16X16_PHASE4_ALIGN_START:-0} ${USB16X16_PHASE4_ALIGN_OFFSET_US:-600} ${USB16X16_PHASE4_ALIGN_TX_TRIGGER:-0} ${USB16X16_PHASE4_ALIGN_TX_OFFSET_US:-600}"
points=("$@")
(( ${#points} == 0 )) && points=(120 480 840)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="$repo_root/outputs/latency/phase4-depth-sweep-$timestamp"
mkdir -p "$output_dir"
print -r -- "output_dir=$output_dir"
print -r -- "wrapper_arguments=$remote_arguments"
print -r -- "points (bridge seconds)=${points[*]}"

if [[ ! -x "$app_binary" ]]; then
    "$harness_dir/build-app.sh"
fi
if ! "$app_binary" inspect --device "USB 16x16" >/dev/null 2>&1; then
    print -r -- "CoreAudio does not expose USB 16x16; refusing"; exit 3
fi

probe() {
    local path=$1
    "$app_binary" measure --device "USB 16x16" --buffer-frames 64 --input-channel 1 --output-channel 1 \
        --impulses 8 --maximum-lag-ms 200 --output "$path" >/dev/null 2>"${path%.json}.log" || return 1
    USB16X16_PROBE="$path" USB16X16_MAX_SPREAD="$max_spread" /usr/bin/python3 - <<'PYEOF'
import json, os
p = json.load(open(os.environ["USB16X16_PROBE"]))
d = p["correlation"]["perImpulseDelaySamples"]
raise SystemExit(0 if float(p["capturedPeak"]) >= 0.01 and max(d) - min(d) <= int(os.environ["USB16X16_MAX_SPREAD"]) else 1)
PYEOF
}

wait_ready() {
    local label=$1 attempts=${2:-90} consecutive=0 n
    for n in $(seq 1 "$attempts"); do
        if probe "$output_dir/probe-$label-$n.json"; then
            (( consecutive += 1 ))
        else
            consecutive=0
        fi
        if (( consecutive >= 3 )); then
            print -r -- "ready label=$label after $n probes"
            return 0
        fi
        sleep 1
    done
    print -r -- "NOT READY label=$label after $attempts probes"
    return 1
}

bridge_seconds() {
    ssh "${ssh_options[@]}" "$pi_target" "grep -c '^BRIDGE' '$remote_result_dir/bridge.log'" 2>/dev/null | tr -d '\n'
}

bridge_state() {
    # Depth per direction (ring plus queue), floors, pitches, biases, and the
    # daemon's sink_min_time, at this moment.
    ssh "${ssh_options[@]}" "$pi_target" "tail -1 '$remote_result_dir/bridge.log' | grep -oE 'tx_occ=[0-9]+|rx_occ=[0-9]+|tx_queue=[0-9]+|rx_queue=[0-9]+|tx_qfloor=[0-9-]+|rx_qfloor=[0-9-]+|pitch=[0-9]+|pitch_p=[0-9]+|tx_bias=[-0-9.]+|rx_bias=[-0-9.]+|tx_restarts=[0-9]+|rx_restarts=[0-9]+' | paste -sd ' '; echo -n ' sink_min_time='; curl -s http://127.0.0.1:8080/api/sink/status/0 | grep -oE '\"sink_min_time\": *[0-9]+' | grep -oE '[0-9]+\$'" 2>/dev/null | tr '\n' ' '
}

ssh "${ssh_options[@]}" "$pi_target" "rm -f '$remote_ready_file'"
print -r -- "=== starting Pi candidate (${candidate_seconds}s) ==="
ssh "${ssh_options[@]}" "$pi_target" \
    "USB16X16_CANDIDATE_SECONDS=$candidate_seconds sudo -n /usr/local/sbin/run-phase4-candidate-safe.sh $remote_arguments" \
    > "$output_dir/candidate.log" 2>&1 &
candidate_pid=$!
remote_result_dir=
for n in $(seq 1 60); do
    remote_result_dir=$(ssh "${ssh_options[@]}" "$pi_target" "test -s '$remote_ready_file' && cat '$remote_ready_file'" 2>/dev/null | sed -n 's/^.*result_dir=//p' | head -1)
    [[ -n "$remote_result_dir" ]] && break
    if ! kill -0 "$candidate_pid" 2>/dev/null; then
        print -r -- "candidate exited before READY"; cat "$output_dir/candidate.log"; exit 2
    fi
    sleep 5
done
if [[ -z "$remote_result_dir" ]]; then
    remote_result_dir=$(ssh "${ssh_options[@]}" "$pi_target" "cat '$remote_ready_file' 2>/dev/null" | tr -d '\n')
fi
print -r -- "READY remote_result_dir=$remote_result_dir"
[[ -z "$remote_result_dir" ]] && { print -r -- "no READY marker"; exit 2; }

sweep_started=$(date +%s)
wait_ready initial 120 || print -r -- "initial readiness failed"

for point in "${points[@]}"; do
    print -r -- ""
    print -r -- "############ point at bridge second $point ############"
    while true; do
        now=$(bridge_seconds)
        [[ -n "$now" ]] && (( now >= point )) && break
        if ! kill -0 "$candidate_pid" 2>/dev/null; then
            print -r -- "candidate ended before point $point"; break 2
        fi
        sleep 5
    done
    state_before=$(bridge_state)
    print -r -- "before: t=$(bridge_seconds)s $state_before"
    result="$output_dir/point-$point.json"
    "$app_binary" measure --device "USB 16x16" --buffer-frames 64 --input-channel 1 --output-channel 1 \
        --impulses "$impulses" --maximum-lag-ms 200 --output "$result" >/dev/null 2>"$output_dir/point-$point.log"
    state_after=$(bridge_state)
    print -r -- "after:  t=$(bridge_seconds)s $state_after"
    if [[ -s "$result" ]]; then
        USB16X16_RESULT="$result" USB16X16_POINT="$point" /usr/bin/python3 - <<'PYEOF'
import json, os, collections
p = json.load(open(os.environ["USB16X16_RESULT"])); c = p["correlation"]; s = c["statistics"]; d = c["perImpulseDelaySamples"]
levels = sorted(collections.Counter(d).items(), key=lambda kv: -kv[1])[:3]
print("point t=%s median=%.3f ms (%d samples) p99=%.3f spread=%d score=%.3f peak=%.3f levels=%s"
      % (os.environ["USB16X16_POINT"], s["medianMilliseconds"], s["medianSamples"], s["p99Milliseconds"],
         max(d) - min(d), c["score"], p["capturedPeak"], levels))
PYEOF
    else
        print -r -- "point t=$point NO MEASUREMENT: $(tail -1 "$output_dir/point-$point.log")"
    fi
done

print -r -- ""
print -r -- "sweep finished after $(( $(date +%s) - sweep_started ))s; waiting for the candidate to end"
wait "$candidate_pid"; candidate_exit=$?
print -r -- "candidate_exit=$candidate_exit"
scp -q -r "${ssh_options[@]}" "$pi_target:$remote_result_dir" "$output_dir/" || true
grep -E "RECOVER|PITCHSERVO" "$output_dir/${remote_result_dir:t}/bridge.log" 2>/dev/null | head
print -r -- "SWEEP DONE"
