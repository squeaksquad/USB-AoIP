#!/bin/zsh
# Live sink playout-delay sweep under one Phase 4 candidate run.
#
# The safe wrapper pins sink delay 576 at start. This starts one candidate,
# waits for the return signal, then for each delay rewrites both sinks over
# the daemon API on the Pi (live, no restart), re-probes readiness, and
# measures a fixed impulse count. One run, one variable, several points.
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
harness_dir="$repo_root/work/latency-harness"
app_binary="$harness_dir/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
pi_target=${USB16X16_PI_TARGET:-bdimaio@192.168.1.201}
ssh_options=(-o BatchMode=yes -o HostKeyAlias=audio-dev.local -o ConnectTimeout=8)
candidate_seconds=${USB16X16_CANDIDATE_SECONDS:-720}
impulses=${USB16X16_SWEEP_IMPULSES:-200}
settle_seconds=${USB16X16_SWEEP_SETTLE_SECONDS:-20}
max_spread=${USB16X16_READY_MAX_SPREAD_SAMPLES:-9}
remote_ready_file=/tmp/usb16x16-phase4-candidate.ready
# wrapper positional arguments: seconds period buffer ring target prime trim txprime rxprime ravenna_playback_buffer
remote_arguments="$candidate_seconds ${USB16X16_PHASE4_PERIOD_FRAMES:-96} ${USB16X16_PHASE4_BUFFER_FRAMES:-192} ${USB16X16_PHASE4_RING_FRAMES:-768} ${USB16X16_PHASE4_TARGET_FRAMES:-192} ${USB16X16_PHASE4_PLAYBACK_PRIME_FRAMES:-96} 0 ${USB16X16_PHASE4_TX_PLAYBACK_PRIME_FRAMES:-192} ${USB16X16_PHASE4_RX_PLAYBACK_PRIME_FRAMES:-96} ${USB16X16_PHASE4_RAVENNA_PLAYBACK_BUFFER_FRAMES:-0} ${USB16X16_PHASE4_SINK_DELAY:-576} ${USB16X16_PHASE4_USB_PITCH_SERVO:-0} ${USB16X16_PHASE4_TX_DEPTH_FRAMES:-0} ${USB16X16_PHASE4_RX_DEPTH_FRAMES:-0} ${USB16X16_PHASE4_LEVEL_GAIN:-0.05}"
delays=("$@")
(( ${#delays} == 0 )) && delays=(576 288 144 96)

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="$repo_root/outputs/latency/phase4-sink-sweep-$timestamp"
mkdir -p "$output_dir"
print -r -- "output_dir=$output_dir"
print -r -- "wrapper_arguments=$remote_arguments"

probe() {
    # one 8-impulse probe; 0 if it carries signal within the spread limit
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
    # three consecutive signal-bearing probes
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
wait_ready initial 120 || { print -r -- "initial readiness failed"; }

for delay in "${delays[@]}"; do
    print -r -- ""
    print -r -- "############ sink delay $delay ############"
    # rewrite both sinks with only the delay changed; verify the readback
    ssh "${ssh_options[@]}" "$pi_target" "DELAY=$delay /usr/bin/python3 - <<'PYEOF'
import json, os, subprocess, sys
delay = int(os.environ['DELAY'])
sinks = json.loads(subprocess.check_output(['curl','-fsS','http://127.0.0.1:8080/api/sinks']))['sinks']
keys = ('name','io','delay','use_sdp','source','sdp','ignore_refclk_gmid','map')
for s in sinks:
    body = {k: s[k] for k in keys}; body['delay'] = delay
    subprocess.check_output(['curl','-fsS','-X','PUT','http://127.0.0.1:8080/api/sink/%d' % s['id'],
                             '-H','Content-Type: application/json','--data-binary', json.dumps(body)])
back = json.loads(subprocess.check_output(['curl','-fsS','http://127.0.0.1:8080/api/sinks']))['sinks']
got = [s['delay'] for s in back]
print('readback delays', got)
sys.exit(0 if got == [delay]*len(got) else 1)
PYEOF" || { print -r -- "point delay=$delay SINK WRITE FAILED"; continue; }
    bridge_line=$(ssh "${ssh_options[@]}" "$pi_target" "grep -c '^BRIDGE' '$remote_result_dir/bridge.log'")
    # The driver's minimum packet arrival lead for sink 0, microseconds, and
    # the bridge depths: the sink delay acts modulo the capture buffer, and
    # this says whether packets now arrive before their slot is read.
    state=$(ssh "${ssh_options[@]}" "$pi_target" "sleep 5; tail -1 '$remote_result_dir/bridge.log' | grep -oE 'tx_occ=[0-9]+|rx_occ=[0-9]+|tx_queue=[0-9]+|rx_queue=[0-9]+|rx_qfloor=[0-9-]+|rx_cappeak=[0-9]+' | paste -sd ' '; echo -n ' sink_min_time='; curl -s http://127.0.0.1:8080/api/sink/status/0 | grep -oE '\"sink_min_time\": *[0-9]+' | grep -oE '[0-9]+\$'" 2>/dev/null | tr '\n' ' ')
    print -r -- "state after apply: $state"
    print -r -- "applied delay=$delay at bridge_second=$bridge_line; settling ${settle_seconds}s"
    sleep "$settle_seconds"
    wait_ready "d$delay" 60
    result="$output_dir/delay-$delay.json"
    "$app_binary" measure --device "USB 16x16" --buffer-frames 64 --input-channel 1 --output-channel 1 \
        --impulses "$impulses" --maximum-lag-ms 200 --output "$result" >/dev/null 2>"$output_dir/delay-$delay.log"
    if [[ -s "$result" ]]; then
        USB16X16_RESULT="$result" USB16X16_DELAY="$delay" /usr/bin/python3 - <<'PYEOF'
import json, os, collections
p = json.load(open(os.environ["USB16X16_RESULT"])); c = p["correlation"]; s = c["statistics"]; d = c["perImpulseDelaySamples"]
levels = sorted(collections.Counter(d).items(), key=lambda kv: -kv[1])[:3]
print("point delay=%s median=%.3f ms (%d samples) p99=%.3f spread=%d score=%.3f peak=%.3f levels=%s"
      % (os.environ["USB16X16_DELAY"], s["medianMilliseconds"], s["medianSamples"], s["p99Milliseconds"],
         max(d) - min(d), c["score"], p["capturedPeak"], levels))
PYEOF
    else
        print -r -- "point delay=$delay NO MEASUREMENT: $(tail -1 "$output_dir/delay-$delay.log")"
    fi
done

print -r -- ""
print -r -- "sweep finished after $(( $(date +%s) - sweep_started ))s; waiting for the candidate to end"
wait "$candidate_pid"; candidate_exit=$?
print -r -- "candidate_exit=$candidate_exit"
scp -q -r "${ssh_options[@]}" "$pi_target:$remote_result_dir" "$output_dir/" || true
grep -E "RECOVER|DEPTHSTEP" "$output_dir/${remote_result_dir:t}/bridge.log" 2>/dev/null | grep -v "t_us=[0-9]\{1,5\} " | head
print -r -- "SWEEP DONE"
