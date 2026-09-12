#!/bin/bash
# An AoIP -> DSP -> AoIP loop candidate: the bridge in --mode aoip-loop.
#
# Copied from run-dsp-candidate-safe.sh (the DSP candidate wrapper) and
# changed where the loop differs, see AOIP_LOOP_DESIGN.md:
#
#   - no USB gate: the loop opens no gadget PCM, so the UDC state and
#     usb-16x16.service are not consulted (the service itself keeps running);
#   - the bridge runs --mode aoip-loop with dsp-direct's TX levers verbatim
#     (period 48, ring 768, target 48, TX prime 192, RAVENNA playback buffer
#     384, sink delay 103, aligned start, aligned TX trigger at 950 us with
#     the aligned prime and the 50 us age margin), the pitch servo off (no
#     gadget) and every RX-only option off;
#   - the preset defaults to loop-measure (transparent, every output -40 dB),
#     because the rig's Ferrofish matrix returns the Pi's output to its own
#     input and any pass-through preset would close a unity feedback loop
#     through the DSP. "none" is refused unless USB16X16_AOIP_LOOP_OPEN=1
#     states that the Ferrofish no longer returns the Pi's stream;
#   - the bridge injects its own impulse (--loop-impulse, channel 1, after the
#     stage) since no host drives the loop; the trace threshold is lowered to
#     0.002 with a 96-frame holdoff so the -40 dB re-emission is stamped too;
#   - tcpdump captures both channel-1 streams on eth0 to tmpfs for a bounded
#     window once the loop runs, and the file moves into the result directory
#     after the bridge has exited (never a transfer during the run);
#   - results land under phase4-aoip-candidate-<UTC>.
#
# Nothing installed is touched. The accepted binary stays at
# /usr/local/libexec/usb16x16-rt-bridge, the supervisor still pins its hash,
# and rolling this back is not running it again. The daemon and module
# lifecycle is the proven one, unchanged, on the installed lead-export module.
#
# Usage: run-aoip-candidate-safe.sh [SECONDS] [DSP_PRESET|none] [IMPULSE_SECONDS]
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root with sudo" >&2
  exit 2
fi

work_root=/home/bdimaio/usb-16x16-work
source_root="$work_root/aes67-daemon-src"
daemon_binary="$source_root/build-daemon/aes67-daemon"
# The installed module (the arrival-lead export on the transmit-slot fix),
# the one the service runs, so the wire stamps mean what the record says.
module_binary="$work_root/ravenna-lead-install/MergingRavennaALSA.ko"
bridge_binary=$work_root/phase4-aoip-src/build/usb16x16-rt-bridge
original_config="$source_root/runtime/daemon-eth0.conf"
original_status="$source_root/runtime/status.json"
expected_daemon_sha256=e31ba2c44cdf07fd6ee0aef7d9a8457bfdd36321cc0407a35275e842b4577416
expected_module_sha256=bc694c24c77893836dd3a3cfa0c9105e68b556d19dd51a84bf9ee5ca3f1b98ff
# The loop-mode candidate build: main.cpp 59cf978d (bridge 947e8b4d's source
# plus --mode aoip-loop and --loop-impulse), built on the Pi 2026-09-12 by
# build-aoip-candidate.sh with the service stopped, zero warnings, core tests
# and the four parser self-checks passed.
expected_bridge_sha256=0a39f4a614898dd55a10f84b3d4d971c0993bf2a44d31179bf11f80e8b70b79f
# loop-measure.dsp: verify-presets.mjs loop-measure, compiled on the Mac
# 2026-09-12 (outputs/dsp-service/aoip-loop-20260912/). transparent.dsp is
# listed too for a run with the Ferrofish loop opened.
expected_dsp_sha256_list="1e417960b8df91483d839814d66a3a27241fca45752bddfd9a09c18f2b594b3c ad69598473691bffdd0808d79d4ff37f4d46ef9f0fa2b34b5fa1f3152b9bbeb9"
expected_gmid=00-1D-C1-FF-FE-1D-27-DC

candidate_seconds=${1:-360}
dsp_preset=${2:-$work_root/aoip-loop/loop-measure.dsp}
impulse_seconds=${3:-2}
# tcpdump window, seconds, started once the loop has been running this long.
capture_seconds=${USB16X16_AOIP_CAPTURE_SECONDS:-30}
capture_after_seconds=${USB16X16_AOIP_CAPTURE_AFTER:-15}
sink_delay=103
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$work_root/logs/phase4-aoip-candidate-$timestamp"
ready_file=/tmp/usb16x16-phase4-candidate.ready
capture_file=/tmp/aoip-loop-$timestamp.pcap
temporary_root=
daemon_pid=
bridge_pid=
capture_pid=
restarts_seen=0

for value in "$candidate_seconds" "$impulse_seconds" "$capture_seconds" "$capture_after_seconds"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "candidate arguments must be unsigned integers" >&2
    exit 10
  fi
done
if [ "$candidate_seconds" -lt 60 ] || [ "$candidate_seconds" -gt 1200 ]; then
  echo "candidate duration must be 60..1200 seconds" >&2
  exit 11
fi
if [ "$impulse_seconds" -lt 1 ] || [ "$impulse_seconds" -gt 60 ]; then
  echo "impulse period must be 1..60 seconds" >&2
  exit 11
fi
if [ "$capture_seconds" -gt 120 ]; then
  echo "capture window must be at most 120 seconds (tmpfs)" >&2
  exit 11
fi
if [ "$dsp_preset" = none ] && [ "${USB16X16_AOIP_LOOP_OPEN:-0}" != 1 ]; then
  echo "refusing 'none': with the Ferrofish returning the Pi's own stream, no preset closes a unity" >&2
  echo "feedback loop through the DSP. Run loop-measure.dsp, or set USB16X16_AOIP_LOOP_OPEN=1 to state" >&2
  echo "that the Ferrofish matrix no longer returns Output 49-64 from Input 49-64." >&2
  exit 42
fi

for process_name in ptp4l aes67-daemon alsaloop; do
  if pgrep -x "$process_name" >/dev/null; then
    echo "refusing to start: $process_name is already running" >&2
    exit 20
  fi
done
if pgrep -f 'usb16x16-rt-bridge([[:space:]]|$)' >/dev/null; then
  echo "refusing to start: a usb16x16-rt-bridge is already running" >&2
  exit 20
fi
if lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing to start: MergingRavennaALSA is already loaded" >&2
  exit 21
fi
if [ "$(cat /sys/class/net/eth0/carrier)" != 1 ] ||
   [ "$(cat /sys/class/net/eth0/speed)" != 1000 ]; then
  echo "refusing to start: eth0 is not at 1 Gb/s with carrier" >&2
  exit 22
fi
# No USB gate here, by design: see the header.
if ! command -v tcpdump >/dev/null; then
  echo "refusing to start: tcpdump is not installed (the wire instrument needs it)" >&2
  exit 23
fi

for required_path in "$daemon_binary" "$module_binary" "$bridge_binary" "$original_config" "$original_status"; do
  if [ ! -r "$required_path" ]; then
    echo "missing required artifact: $required_path" >&2
    exit 24
  fi
done
if [ "$(sha256sum "$daemon_binary" | awk '{print $1}')" != "$expected_daemon_sha256" ]; then
  echo "AES67 daemon hash mismatch" >&2
  exit 25
fi
if [ "$(sha256sum "$module_binary" | awk '{print $1}')" != "$expected_module_sha256" ]; then
  echo "RAVENNA module hash mismatch" >&2
  exit 26
fi
if [ "$(sha256sum "$bridge_binary" | awk '{print $1}')" != "$expected_bridge_sha256" ]; then
  echo "candidate bridge hash mismatch (expected $expected_bridge_sha256)" >&2
  exit 27
fi
if [ "$dsp_preset" != none ]; then
  if [ ! -r "$dsp_preset" ]; then
    echo "missing DSP preset: $dsp_preset" >&2
    exit 40
  fi
  dsp_actual_sha256=$(sha256sum "$dsp_preset" | awk '{print $1}')
  dsp_known=0
  for known in $expected_dsp_sha256_list; do
    [ "$dsp_actual_sha256" = "$known" ] && dsp_known=1
  done
  if [ "$dsp_known" -ne 1 ]; then
    echo "DSP preset hash $dsp_actual_sha256 is not one this wrapper will run" >&2
    exit 41
  fi
fi

original_config_sha256=$(sha256sum "$original_config" | awk '{print $1}')
original_status_sha256=$(sha256sum "$original_status" | awk '{print $1}')
temporary_root=$(mktemp -d /tmp/usb16x16-phase4-candidate.XXXXXX)
mkdir -p "$result_dir"
rm -f "$ready_file"

cleanup() {
  set +e
  rm -f "$ready_file"
  if [ -n "$capture_pid" ] && kill -0 "$capture_pid" 2>/dev/null; then
    kill -INT "$capture_pid"
    wait "$capture_pid" 2>/dev/null
  fi
  if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null; then
    kill -INT "$bridge_pid"
    for attempt in 1 2 3 4 5; do
      kill -0 "$bridge_pid" 2>/dev/null || break
      sleep 1
    done
    kill -TERM "$bridge_pid" 2>/dev/null || true
  fi
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -INT "$daemon_pid"
    for attempt in 1 2 3 4 5; do
      kill -0 "$daemon_pid" 2>/dev/null || break
      sleep 1
    done
    kill -TERM "$daemon_pid" 2>/dev/null || true
  fi
  for attempt in 1 2 3 4 5; do
    if ! lsmod | grep -q '^MergingRavennaALSA '; then
      break
    fi
    /usr/sbin/rmmod MergingRavennaALSA 2>/dev/null || true
    sleep 1
  done
  # The capture leaves tmpfs only now, with the bridge gone.
  if [ -s "$capture_file" ]; then
    mv -f "$capture_file" "$result_dir/" 2>/dev/null || true
  fi
  rm -f "$capture_file"
  case "$temporary_root" in
    /tmp/usb16x16-phase4-candidate.*) rm -rf "$temporary_root" ;;
  esac
  chown -R bdimaio:bdimaio "$result_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

sed "s|\"status_file\": \"[^\"]*\"|\"status_file\": \"$temporary_root/status.json\"|" \
  "$original_config" > "$temporary_root/daemon.conf"
sed "s/\"delay\": 576/\"delay\": $sink_delay/g" "$original_status" > "$temporary_root/status.json"

for sink_id in 0 1; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); keys=("name","io","delay","use_sdp","source","sdp","ignore_refclk_gmid","map"); json.dump({k:d["sinks"][int(sys.argv[3])][k] for k in keys},open(sys.argv[2],"w"))' \
    "$temporary_root/status.json" "$temporary_root/sink-$sink_id.json" "$sink_id"
done

/usr/sbin/insmod "$module_binary"
"$daemon_binary" -c "$temporary_root/daemon.conf" > "$result_dir/daemon.log" 2>&1 &
daemon_pid=$!

api_ready=0
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8080/api/ptp/status > "$result_dir/ptp-status.json"; then
    api_ready=1
    break
  fi
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 1
done
if [ "$api_ready" -ne 1 ]; then
  echo "AES67 daemon API did not become ready" >&2
  exit 28
fi

ptp_locked=0
for attempt in $(seq 1 90); do
  curl -fsS http://127.0.0.1:8080/api/ptp/status > "$result_dir/ptp-status.json"
  if grep -Eq '"status"[[:space:]]*:[[:space:]]*"locked"' "$result_dir/ptp-status.json" &&
     grep -qi "$expected_gmid" "$result_dir/ptp-status.json"; then
    ptp_locked=1
    break
  fi
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 1
done
if [ "$ptp_locked" -ne 1 ]; then
  echo "PTP did not lock to expected GMID $expected_gmid" >&2
  exit 29
fi

for sink_id in 0 1; do
  curl -fsS -X PUT "http://127.0.0.1:8080/api/sink/$sink_id" \
    -H 'Content-Type: application/json' \
    --data-binary "@$temporary_root/sink-$sink_id.json" \
    > "$result_dir/sink-$sink_id-put.json"
done
curl -fsS http://127.0.0.1:8080/api/sinks > "$result_dir/sinks-readback.json"
if [ "$(grep -o "\"delay\"[[:space:]]*:[[:space:]]*$sink_delay\b" "$result_dir/sinks-readback.json" | wc -l)" -ne 2 ]; then
  echo "sink delay readback did not contain two $sink_delay-sample sinks" >&2
  exit 30
fi

# dsp-direct's TX side, verbatim, plus the loop mode; every RX-only option
# off and the pitch servo off, which the bridge itself enforces for the mode.
# The trace threshold and holdoff are the loop's: the -40 dB re-emission
# (0.0025 full scale) must be stamped, and it follows its return by less than
# the default 2400-frame holdoff.
bridge_arguments=(
  --mode aoip-loop
  --period 48 --buffer 192 --ring 768 --target 48
  --playback-prime 96 --prime-trim 0 --rx-prime-trim 0
  --tx-playback-prime 192 --rx-playback-prime 0
  --ravenna-playback-buffer 384
  --usb-pitch-servo 0 --tx-depth 0 --rx-depth 0 --level-gain 0.05
  --align-start 1 --align-offset-us 600
  --align-tx-trigger 1 --align-tx-offset-us 950 --align-tx-prime 1
  --align-rx-trigger 0 --align-rx-offset-us 600 --align-rx-prime 0
  --align-prime-age-margin-us 50
  --zero-run-detect 1
  --impulse-trace 1 --impulse-channel 1 --impulse-threshold 0.002 --impulse-holdoff 96
  --loop-impulse "1,$impulse_seconds"
  --pitch-seed 0 --level-shift 0
  --priority 90
  --seconds "$candidate_seconds"
)
if [ "$dsp_preset" != none ]; then
  bridge_arguments+=(--dsp-preset "$dsp_preset")
fi
timeout -k 5 -s INT "$candidate_seconds" "$bridge_binary" "${bridge_arguments[@]}" \
  > "$result_dir/bridge.log" 2>&1 &
bridge_pid=$!

sleep 4
if ! kill -0 "$bridge_pid" 2>/dev/null; then
  echo "loop bridge exited during startup" >&2
  exit 31
fi
if ! grep -q '^NEGOTIATED mode=aoip-loop ' "$result_dir/bridge.log"; then
  echo "loop bridge did not report NEGOTIATED mode=aoip-loop" >&2
  exit 32
fi
if grep -Eq '^BRIDGE .*tx_restarts=[1-9][0-9]*' "$result_dir/bridge.log"; then
  echo "loop bridge restarted the direction during startup" >&2
  exit 33
fi

{
  echo "result_dir=$result_dir"
  echo "mode=aoip-loop"
  echo "sink_delay=$sink_delay"
  echo "candidate_seconds=$candidate_seconds"
  echo "impulse_seconds=$impulse_seconds"
  echo "dsp_preset=$dsp_preset"
  echo "dsp_sha256=$([ "$dsp_preset" = none ] && echo none || sha256sum "$dsp_preset" | awk '{print $1}')"
  echo "module_sha256=$expected_module_sha256"
  echo "bridge_binary=$bridge_binary"
  echo "bridge_sha256=$(sha256sum "$bridge_binary" | awk '{print $1}')"
  echo "bridge_arguments=${bridge_arguments[*]}"
  # CLOCK_REALTIME minus CLOCK_MONOTONIC, for rtp-impulses.py --mono-offset.
  echo "mono_offset=$(python3 -c 'import time; print(time.time() - time.monotonic())')"
  echo "capture_file=$(basename "$capture_file")"
  echo "capture_seconds=$capture_seconds"
} > "$result_dir/metadata.txt"
echo "$result_dir" > "$ready_file"
echo "READY result_dir=$result_dir"

# A direction restart is counted, not fatal, as in the DSP wrapper; a
# runaway is still fatal.
restart_limit=${USB16X16_DSP_RESTART_LIMIT:-8}
elapsed=0
while kill -0 "$bridge_pid" 2>/dev/null; do
  if [ -z "$capture_pid" ] && [ "$capture_seconds" -gt 0 ] && [ "$elapsed" -ge "$capture_after_seconds" ]; then
    timeout "$capture_seconds" tcpdump -i eth0 -s 1500 -B 65536 -w "$capture_file" \
      'udp and dst port 5004 and (dst host 239.69.16.1 or dst host 239.69.121.9)' \
      > "$result_dir/tcpdump.log" 2>&1 &
    capture_pid=$!
    echo "capture started: $capture_file for ${capture_seconds}s"
  fi
  restarts_seen=$(awk '/^BRIDGE /{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^tx_restarts=/) { split($i, a, "="); tx = a[2] }
      }
    } END { print tx + 0 }' "$result_dir/bridge.log" 2>/dev/null)
  restarts_seen=${restarts_seen:-0}
  if [ "$restarts_seen" -gt "$restart_limit" ]; then
    echo "loop bridge restarted the direction $restarts_seen times, over the limit of $restart_limit" >&2
    exit 33
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
echo "direction_restarts=$restarts_seen" >> "$result_dir/metadata.txt"
if [ "$restarts_seen" -gt 0 ]; then
  echo "note: $restarts_seen direction restart(s) during the candidate, counted not fatal" >&2
fi

set +e
wait "$bridge_pid"
bridge_status=$?
set -e
bridge_pid=
case "$bridge_status" in
  0|124|130|143) ;;
  *)
    echo "loop bridge failed with status $bridge_status" >&2
    exit 34
    ;;
esac
if grep -v '^RECOVER ' "$result_dir/bridge.log" |
   grep -Eqi 'fatal:|xrun|overrun|underrun|broken pipe|restart[^s]'; then
  echo "loop bridge log contains a failure marker outside a counted RECOVER" >&2
  exit 35
fi
if [ "$(sha256sum "$original_config" | awk '{print $1}')" != "$original_config_sha256" ] ||
   [ "$(sha256sum "$original_status" | awk '{print $1}')" != "$original_status_sha256" ]; then
  echo "protected AES67 prototype config changed during the candidate" >&2
  exit 36
fi
grep '^SUMMARY ' "$result_dir/bridge.log" | tail -1 | cut -c9- > "$result_dir/summary.json" || true
echo "DONE result_dir=$result_dir"
