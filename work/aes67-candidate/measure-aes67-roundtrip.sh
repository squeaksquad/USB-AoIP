#!/bin/zsh
set -euo pipefail

# Orchestrates the complete digital round trip:
#   Mac CoreAudio out -> USB 16x16 -> Pi -> AES67 TX -> Ferrofish digital loop
#   -> AES67 RX -> Pi -> USB 16x16 -> Mac CoreAudio in
#
# The Pi side is the existing reversible wrapper run-aes67-candidate-safe.sh.
# The Mac side is the existing CoreAudio impulse-correlation harness. This
# script only sequences them and collects the artifacts; it starts no new
# measurement method of its own.

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
harness_dir="$repo_root/work/latency-harness"
app_binary="$harness_dir/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
pi_target=${USB16X16_PI_TARGET:-bdimaio@192.168.1.201}
pi_alias=${USB16X16_PI_HOST_KEY_ALIAS:-audio-dev.local}
remote_script=${USB16X16_REMOTE_CANDIDATE:-/usr/local/sbin/run-aes67-candidate-safe.sh}
remote_ready_file=${USB16X16_REMOTE_READY_FILE:-/tmp/usb16x16-aes67-candidate.ready}
path_label=${USB16X16_PATH_LABEL:-Ferrofish return path}
path_hint=${USB16X16_PATH_HINT:-Route the Ferrofish inputs 49-64 back out to the two flows the Pi subscribes to.}

candidate_seconds=${1:-120}
coreaudio_frames=${2:-64}
impulse_count=${3:-40}
maximum_lag_ms=${4:-500}
settle_seconds=${USB16X16_SETTLE_SECONDS:-8}

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="$repo_root/outputs/latency"
result_path="$output_dir/aes67-roundtrip-${coreaudio_frames}f-${timestamp}.json"
measure_log="$output_dir/aes67-roundtrip-${coreaudio_frames}f-${timestamp}-measure.log"
candidate_log="$output_dir/aes67-roundtrip-${coreaudio_frames}f-${timestamp}-candidate.log"
api_dir="$output_dir/aes67-roundtrip-${coreaudio_frames}f-${timestamp}-api"

ssh_options=(
    -o BatchMode=yes
    -o "HostKeyAlias=$pi_alias"
    -o ConnectTimeout=8
)

mkdir -p "$output_dir" "$api_dir"

# The Pi wrapper samples sink status once, immediately after the PUT and before
# the loops open RAVENNA capture, when the receive flags are still latched.
# Sampling the live daemon again around the measurement is what actually shows
# whether the Ferrofish is returning the transmit streams.
api_snapshot() {
    local label=$1
    ssh "${ssh_options[@]}" "$pi_target" \
        "for endpoint in ptp/status sources sinks sink/status/0 sink/status/1 browse/sources/all; do
            echo \"===\$endpoint\"
            curl -fsS --max-time 5 \"http://127.0.0.1:8080/api/\$endpoint\" || echo '{}'
            echo
        done" > "$api_dir/$label.txt" 2>/dev/null || true
}

if [[ ! -x "$app_binary" ]]; then
    "$harness_dir/build-app.sh"
fi

print -r -- "=== pre-flight ==="

# The protected USB baseline and a clean AES67 slate are preconditions. The Pi
# wrapper re-checks these itself; failing here avoids a pointless sudo prompt.
ssh "${ssh_options[@]}" "$pi_target" \
    "set -eu
    for process_name in ptp4l aes67-daemon alsaloop; do
        if pgrep -x \"\$process_name\" >/dev/null; then
            echo \"\$process_name is already running\" >&2
            exit 20
        fi
    done
    if lsmod | grep -q '^MergingRavennaALSA '; then
        echo 'MergingRavennaALSA is already loaded' >&2
        exit 21
    fi
    test \"\$(cat /sys/class/udc/*/state)\" = configured
    test \"\$(cat /sys/class/udc/*/current_speed)\" = high-speed
    test \"\$(systemctl is-active usb-16x16.service)\" = active
    test -x '$remote_script'
    rm -f '$remote_ready_file'"
print -r -- "pi: clean, usb configured/high-speed, usb-16x16.service active"

# CoreAudio must currently own the device. The 2026-08-31 combined attempt was
# wasted because macOS had silently dropped USB enumeration.
if ! "$app_binary" inspect --device "USB 16x16" >/dev/null 2>&1; then
    print -ru2 -- "error: CoreAudio does not expose 'USB 16x16'."
    print -ru2 -- "Reconnect the USB data cable and confirm the device in Audio MIDI Setup."
    exit 3
fi
print -r -- "mac: CoreAudio exposes USB 16x16"
print -r -- ""
print -r -- "Return path under test: $path_label"
print -r -- ""

# The measurement watcher waits for the Pi wrapper's READY marker, then runs the
# existing harness. It runs in the background so the candidate ssh session keeps
# the real terminal for its one sudo password prompt.
measure_status_file=$(mktemp -t usb16x16-measure-status)
remote_result_file=$(mktemp -t usb16x16-remote-result)

{
    set +e
    remote_result_dir=$(ssh "${ssh_options[@]}" "$pi_target" \
        "for attempt in \$(seq 1 240); do
            if test -s '$remote_ready_file'; then
                cat '$remote_ready_file'
                exit 0
            fi
            sleep 1
        done
        exit 1")
    if [[ -z "$remote_result_dir" ]]; then
        print -r -- "1" > "$measure_status_file"
        print -ru2 -- "candidate never reported READY"
        exit 0
    fi
    print -r -- "$remote_result_dir" > "$remote_result_file"

    # A fixed settle is not enough: for several seconds after the loops start
    # the sinks latch rtp_seq_id_error and rtp_sac_error while the receive
    # stream aligns. Measuring during that window captures nothing. Wait for
    # both sinks to report clean flags instead of guessing a duration.
    sleep "$settle_seconds"
    for settle_attempt in {1..40}; do
        if ssh "${ssh_options[@]}" "$pi_target" \
            "for sink_id in 0 1; do
                curl -fsS --max-time 4 \"http://127.0.0.1:8080/api/sink/status/\$sink_id\" || exit 1
            done" 2>/dev/null \
            | tr -d '\n ' \
            | grep -q '"rtp_seq_id_error":false,"rtp_ssrc_error":false,"rtp_payload_type_error":false,"rtp_sac_error":false,"receiving_rtp_packet":true'
        then
            print -r -- "sinks clean after ${settle_attempt} check(s)" > "$api_dir/settle.log"
            settle_ok=1
            break
        fi
        sleep 2
    done
    if [[ -z "${settle_ok-}" ]]; then
        print -r -- "sinks never reported clean flags" > "$api_dir/settle.log"
    fi
    api_snapshot before-measurement
    "$app_binary" measure \
        --device "USB 16x16" \
        --buffer-frames "$coreaudio_frames" \
        --input-channel 1 \
        --output-channel 1 \
        --impulses "$impulse_count" \
        --maximum-lag-ms "$maximum_lag_ms" \
        --output "$result_path" \
        >/dev/null 2>"$measure_log"
    measure_exit_code=$?
    api_snapshot after-measurement
    print -r -- "$measure_exit_code" > "$measure_status_file"
} &
watcher_pid=$!

# Tuning variables set on the Mac are forwarded to the Pi wrapper. They cross
# the sudo boundary through the env_keep list in /etc/sudoers.d/usb16x16-latency,
# so `sudo env` is not needed and /usr/bin/env is never granted.
remote_environment="USB16X16_CANDIDATE_SECONDS=$candidate_seconds"
for forwarded_name in \
    USB16X16_SINK_DELAY \
    USB16X16_PERIOD_FRAMES \
    USB16X16_BUFFER_FRAMES \
    USB16X16_TARGET_USEC
do
    forwarded_value=${(P)forwarded_name-}
    if [[ -n "$forwarded_value" ]]; then
        remote_environment+=" $forwarded_name=$forwarded_value"
        print -r -- "forwarding $forwarded_name=$forwarded_value"
    fi
done

print -r -- "=== starting Pi candidate (${candidate_seconds}s) ==="
set +e
ssh "${ssh_options[@]}" "$pi_target" \
    "$remote_environment sudo -n $remote_script" > "$candidate_log" 2>&1 &
candidate_pid=$!
wait "$candidate_pid"
candidate_status=$?
set -e
[[ -s "$candidate_log" ]] && sed 's/^/  pi| /' "$candidate_log"

for _ in {1..20}; do
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$watcher_pid" 2>/dev/null; then
    print -ru2 -- "candidate ended without a measurement; stopping the watcher"
    kill -TERM "$watcher_pid" 2>/dev/null || true
fi
wait "$watcher_pid" 2>/dev/null || true
measure_status=$(cat "$measure_status_file" 2>/dev/null || print -r -- 1)
remote_result_dir=$(cat "$remote_result_file" 2>/dev/null || print -r -- "")
rm -f "$measure_status_file" "$remote_result_file"

if [[ -n "$remote_result_dir" ]]; then
    scp -q -r "${ssh_options[@]}" "$pi_target:$remote_result_dir" "$output_dir/" || true
fi

print -r -- ""
print -r -- "=== post-run verification ==="
ssh "${ssh_options[@]}" "$pi_target" \
    "test -z \"\$(pgrep -x alsaloop || true)\"
    test -z \"\$(pgrep -x aes67-daemon || true)\"
    test -z \"\$(pgrep -x ptp4l || true)\"
    ! lsmod | grep -q '^MergingRavennaALSA '
    test \"\$(cat /sys/class/udc/*/state)\" = configured
    test \"\$(cat /sys/class/udc/*/current_speed)\" = high-speed
    test \"\$(systemctl is-active usb-16x16.service)\" = active"
print -r -- "pi: cleaned up, usb configured/high-speed, usb-16x16.service active"

print -r -- ""
print -r -- "candidate_exit=$candidate_status"
print -r -- "measure_exit=$measure_status"
[[ -n "$remote_result_dir" ]] && print -r -- "pi_logs=$output_dir/${remote_result_dir:t}"
print -r -- "api_snapshots=$api_dir"
print -r -- "candidate_log=$candidate_log"

if [[ -s "$api_dir/after-measurement.txt" ]]; then
    print -r -- ""
    print -r -- "=== AES67 daemon state during the run ==="
    USB16X16_API_SNAPSHOT="$api_dir/after-measurement.txt" \
        USB16X16_PATH_LABEL="$path_label" \
        USB16X16_PATH_HINT="$path_hint" \
        /usr/bin/python3 <<'PYEOF'
import json
import os

blocks = {}
name = None
buffer = []
with open(os.environ["USB16X16_API_SNAPSHOT"]) as handle:
    for line in handle:
        if line.startswith("==="):
            if name is not None:
                blocks[name] = "".join(buffer)
            name = line[3:].strip()
            buffer = []
        else:
            buffer.append(line)
if name is not None:
    blocks[name] = "".join(buffer)


def parsed(key):
    try:
        return json.loads(blocks.get(key, ""))
    except (ValueError, TypeError):
        return None


ptp = parsed("ptp/status")
if ptp:
    print("ptp          %s  gmid=%s" % (ptp.get("status"), ptp.get("gmid")))

sources = parsed("sources")
if sources is not None:
    entries = sources.get("sources", sources) if isinstance(sources, dict) else sources
    print("tx sources   %d announced" % len(entries))

returning = None
for sink_id in (0, 1):
    status = parsed("sink/status/%d" % sink_id)
    if not status:
        continue
    flags = status.get("sink_flags", {})
    receiving = bool(flags.get("receiving_rtp_packet"))
    muted = bool(flags.get("all_muted"))
    healthy = receiving and not muted
    returning = healthy if returning is None else (returning and healthy)
    print(
        "sink %d       receiving_rtp=%s all_muted=%s seq_err=%s ssrc_err=%s"
        % (
            sink_id,
            receiving,
            muted,
            bool(flags.get("rtp_seq_id_error")),
            bool(flags.get("rtp_ssrc_error")),
        )
    )

label = os.environ.get("USB16X16_PATH_LABEL", "return path")
print("")
if returning is True:
    print("%s: RECEIVING. A measured delay is trustworthy." % label)
elif returning is False:
    print("%s: NOT delivering audio to the Pi sinks." % label)
    print(os.environ.get("USB16X16_PATH_HINT", ""))
else:
    print("%s: sink status unavailable." % label)
PYEOF
fi

if [[ "$measure_status" != 0 ]]; then
    print -ru2 -- ""
    print -ru2 -- "no measurement was produced; harness stderr:"
    [[ -s "$measure_log" ]] && cat "$measure_log" >&2
    exit 4
fi

print -r -- "result=$result_path"
print -r -- ""
plutil -extract correlation.score raw -o - "$result_path"
plutil -extract capturedPeak raw -o - "$result_path"
plutil -extract correlation.statistics json -o - "$result_path"

if (( candidate_status != 0 )); then
    print -ru2 -- ""
    print -ru2 -- "warning: the Pi candidate exited non-zero; treat the number as"
    print -ru2 -- "reconnaissance only until a clean run reproduces it."
    exit 5
fi
