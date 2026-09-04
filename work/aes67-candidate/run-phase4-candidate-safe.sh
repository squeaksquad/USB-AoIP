#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root with sudo" >&2
  exit 2
fi

work_root=/home/bdimaio/usb-16x16-work
source_root="$work_root/aes67-daemon-src"
daemon_binary="$source_root/build-daemon/aes67-daemon"
module_binary="$work_root/aes67-source/ravenna-alsa-lkm-v2.1/driver/MergingRavennaALSA.ko"
bridge_binary=/usr/local/libexec/usb16x16-rt-bridge
original_config="$source_root/runtime/daemon-eth0.conf"
original_status="$source_root/runtime/status.json"
expected_daemon_sha256=e31ba2c44cdf07fd6ee0aef7d9a8457bfdd36321cc0407a35275e842b4577416
expected_module_sha256=f65a49558a0f8f16efbbe7afa45464d41529faacfcb1a838e897f99d9649604e
expected_bridge_sha256=b65b84ee2aa33cde52e99a8275730c19be2269b5d55904382aeb17b341a33118
expected_gmid=00-1D-C1-FF-FE-1D-27-DC

candidate_seconds=${1:-360}
period_frames=${2:-96}
buffer_frames=${3:-384}
ring_frames=${4:-768}
target_frames=${5:-192}
# Frames primed into the ALSA playback queue. Zero keeps the historical
# behaviour of priming the whole playback buffer. This is the ring/queue split
# knob; the elastic ring keeps target_frames as the jitter reservoir.
playback_prime_frames=${6:-0}
# Discard the ring overshoot at prime time (0 or 1). The overshoot is otherwise
# permanent pipeline depth, because depth is conserved after priming.
prime_trim=${7:-0}
# Per-direction prime overrides; 0 inherits playback_prime_frames. tx is
# usb-to-ravenna (RAVENNA playback), rx is ravenna-to-usb (USB playback).
tx_playback_prime_frames=${8:-0}
rx_playback_prime_frames=${9:-0}
# Buffer request for the RAVENNA playback PCM alone; 0 inherits buffer_frames.
# Lifts TX's queue-floor ceiling without moving the RAVENNA capture buffer.
ravenna_playback_buffer_frames=${10:-0}
# AES67 sink playout delay in samples, applied to both sinks before the bridge
# primes. Changing it live after priming never reaches the bridge (sweep
# 022225Z), so the value the run starts with is the one that can matter.
sink_delay=${11:-576}
# Phase 5 step 1: 1 steers the USB gadget pitch controls to the PTP rate and
# runs both converters at exactly 1.0 (bit transparent); 0 is the resampler.
usb_pitch_servo=${12:-0}
# Mode 2 depth setpoints (ring plus playback queue, frames); 0 captures the
# depth at engagement. Only meaningful with usb_pitch_servo=2.
tx_depth_frames=${13:-0}
rx_depth_frames=${14:-0}
# Mode 2 level gain in ppm per frame of depth error, (0, 0.1]. 0.05 turns 20
# frames into 1 ppm; 0.01 sat in the 1 ppm quantisation dead zone (142307Z).
level_gain=${15:-0.05}
# Aligned start (0 or 1): the bridge times eight RAVENNA capture wakeups,
# then re-prepares that capture align_offset_us after the last one, so the
# driver's reader phase (fixed at prepare, anywhere inside a 1 ms tick) is a
# constant instead of a per-session draw. Offset in microseconds, 0..10000;
# a non-default offset needs align_start=1.
align_start=${16:-0}
align_offset_us=${17:-600}
# Aligned TX trigger (0 or 1): the RAVENNA playback trigger, at start and at
# every TX recovery, waits for the next tick-grid point plus
# align_tx_offset_us on the grid the aligned start measured, so the trigger's
# phase inside a 1 ms tick (the last per-session draw, up to 48 frames on TX)
# is a constant. Needs align_start=1; a non-default offset needs
# align_tx_trigger=1.
align_tx_trigger=${18:-0}
align_tx_offset_us=${19:-600}
# Aligned TX prime (0 or 1): the prime waits for one more period of ring and
# drops from the ring's front the frames that make the front frame's age at
# the first tick after the trigger a constant. Needs align_tx_trigger=1.
align_tx_prime=${20:-0}
# Zero-run detector (0 or 1): the bridge scans every block entering and
# leaving it for per-channel runs of exact zeros (8 to 480 frames) and logs
# each as a ZERORUN line naming its stage, so the 41-sample holes can be
# placed on the leg that makes them. Behaviour-free; off by default.
zero_run_detect=${21:-0}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$work_root/logs/phase4-candidate-$timestamp"
ready_file=/tmp/usb16x16-phase4-candidate.ready
temporary_root=
daemon_pid=
bridge_pid=

for value in "$candidate_seconds" "$period_frames" "$buffer_frames" "$ring_frames" "$target_frames" \
             "$playback_prime_frames" "$prime_trim" \
             "$tx_playback_prime_frames" "$rx_playback_prime_frames" \
             "$ravenna_playback_buffer_frames" "$sink_delay" "$usb_pitch_servo" \
             "$tx_depth_frames" "$rx_depth_frames" "$align_start" "$align_offset_us" \
             "$align_tx_trigger" "$align_tx_offset_us" "$align_tx_prime" "$zero_run_detect"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "candidate arguments must be unsigned integers" >&2
    exit 10
  fi
done
if [ "$candidate_seconds" -lt 60 ] || [ "$candidate_seconds" -gt 1200 ]; then
  echo "candidate duration must be 60..1200 seconds" >&2
  exit 11
fi
if { [ "$period_frames" -ne 48 ] && [ "$period_frames" -ne 96 ]; } ||
   [ "$buffer_frames" -lt $((period_frames * 2)) ] ||
   [ "$ring_frames" -lt $((target_frames + 8)) ] ||
   [ "$target_frames" -lt "$period_frames" ]; then
  echo "invalid period/buffer/ring/target relationship" >&2
  exit 12
fi
if [ "$playback_prime_frames" -ne 0 ] &&
   { [ "$playback_prime_frames" -lt "$period_frames" ] ||
     [ "$playback_prime_frames" -gt "$buffer_frames" ] ||
     [ "$ring_frames" -lt $((target_frames + playback_prime_frames + 4)) ]; }; then
  echo "invalid playback-prime relationship" >&2
  exit 13
fi
if [ "$prime_trim" -ne 0 ] && [ "$prime_trim" -ne 1 ]; then
  echo "prime-trim must be 0 or 1" >&2
  exit 14
fi
if [ "$usb_pitch_servo" -gt 2 ]; then
  echo "usb-pitch-servo must be 0, 1 or 2" >&2
  exit 14
fi
if ! [[ "$level_gain" =~ ^0\.[0-9]{1,3}$ ]] || [ "$level_gain" = 0.000 ] || [ "$level_gain" = 0.00 ] || [ "$level_gain" = 0.0 ]; then
  echo "level-gain must be a decimal in (0, 0.1], e.g. 0.05" >&2
  exit 14
fi
if [ "$usb_pitch_servo" -ne 2 ] && [ "$level_gain" != 0.05 ]; then
  echo "level-gain needs usb-pitch-servo 2" >&2
  exit 14
fi
if [ "$usb_pitch_servo" -ne 2 ] && { [ "$tx_depth_frames" -ne 0 ] || [ "$rx_depth_frames" -ne 0 ]; }; then
  echo "tx/rx depth setpoints need usb-pitch-servo 2" >&2
  exit 14
fi
if [ "$align_start" -gt 1 ]; then
  echo "align-start must be 0 or 1" >&2
  exit 14
fi
if [ "$align_offset_us" -gt 10000 ]; then
  echo "align-offset-us must be 0..10000" >&2
  exit 14
fi
if [ "$align_start" -ne 1 ] && [ "$align_offset_us" -ne 600 ]; then
  echo "align-offset-us needs align-start 1" >&2
  exit 14
fi
if [ "$align_tx_trigger" -gt 1 ]; then
  echo "align-tx-trigger must be 0 or 1" >&2
  exit 14
fi
if [ "$align_tx_offset_us" -gt 10000 ]; then
  echo "align-tx-offset-us must be 0..10000" >&2
  exit 14
fi
if [ "$align_tx_trigger" -ne 1 ] && [ "$align_tx_offset_us" -ne 600 ]; then
  echo "align-tx-offset-us needs align-tx-trigger 1" >&2
  exit 14
fi
if [ "$align_tx_trigger" -eq 1 ] && [ "$align_start" -ne 1 ]; then
  echo "align-tx-trigger needs align-start 1" >&2
  exit 14
fi
if [ "$align_tx_prime" -gt 1 ]; then
  echo "align-tx-prime must be 0 or 1" >&2
  exit 14
fi
if [ "$align_tx_prime" -eq 1 ] && [ "$align_tx_trigger" -ne 1 ]; then
  echo "align-tx-prime needs align-tx-trigger 1" >&2
  exit 14
fi
if [ "$zero_run_detect" -gt 1 ]; then
  echo "zero-run-detect must be 0 or 1" >&2
  exit 14
fi
if [ "$tx_depth_frames" -ne 0 ] && [ "$tx_depth_frames" -lt $((target_frames + 144 + period_frames)) ]; then
  echo "tx-depth is below target + 144 (skip cover) + one period" >&2
  exit 14
fi
if [ "$rx_depth_frames" -ne 0 ] && [ "$rx_depth_frames" -lt $((target_frames + 2 * period_frames)) ]; then
  echo "rx-depth is below target + two periods" >&2
  exit 14
fi
if [ "$ravenna_playback_buffer_frames" -ne 0 ] &&
   { [ "$ravenna_playback_buffer_frames" -lt $((period_frames * 2)) ] ||
     [ "$ravenna_playback_buffer_frames" -gt 2048 ]; }; then
  echo "invalid ravenna-playback-buffer" >&2
  exit 16
fi
if [ "$sink_delay" -lt 48 ] || [ "$sink_delay" -gt 2400 ]; then
  echo "sink delay must be 48..2400 samples" >&2
  exit 17
fi
# tx primes into RAVENNA playback, so it validates against that PCM's own
# request when one is given; rx primes into USB playback at buffer_frames.
tx_prime_buffer_limit=$buffer_frames
if [ "$ravenna_playback_buffer_frames" -ne 0 ]; then
  tx_prime_buffer_limit=$ravenna_playback_buffer_frames
fi
for pair in "$tx_playback_prime_frames:$tx_prime_buffer_limit" "$rx_playback_prime_frames:$buffer_frames"; do
  value=${pair%%:*}
  limit=${pair##*:}
  if [ "$value" -ne 0 ] &&
     { [ "$value" -lt "$period_frames" ] ||
       [ "$value" -gt "$limit" ] ||
       [ "$ring_frames" -lt $((target_frames + value + 4)) ]; }; then
    echo "invalid per-direction playback-prime relationship" >&2
    exit 15
  fi
done

for process_name in ptp4l aes67-daemon alsaloop; do
  if pgrep -x "$process_name" >/dev/null; then
    echo "refusing to start: $process_name is already running" >&2
    exit 20
  fi
done
if pgrep -f '^/usr/local/libexec/usb16x16-rt-bridge([[:space:]]|$)' >/dev/null; then
  echo "refusing to start: usb16x16-rt-bridge is already running" >&2
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
if [ "$(cat /sys/class/udc/*/state)" != configured ] ||
   [ "$(cat /sys/class/udc/*/current_speed)" != high-speed ] ||
   [ "$(systemctl is-active usb-16x16.service)" != active ]; then
  echo "refusing to start: protected USB baseline is not healthy" >&2
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
if [ "$(sha256sum "$bridge_binary" | awk '{print $1}')" != "$expected_bridge_sha256" ] ||
   [ "$(stat -c '%U:%G:%a' "$bridge_binary")" != root:root:755 ]; then
  echo "Phase 4 bridge hash or ownership mismatch" >&2
  exit 27
fi

original_config_sha256=$(sha256sum "$original_config" | awk '{print $1}')
original_status_sha256=$(sha256sum "$original_status" | awk '{print $1}')
temporary_root=$(mktemp -d /tmp/usb16x16-phase4-candidate.XXXXXX)
mkdir -p "$result_dir"
rm -f "$ready_file"

cleanup() {
  set +e
  rm -f "$ready_file"
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
  case "$temporary_root" in
    /tmp/usb16x16-phase4-candidate.*) rm -rf "$temporary_root" ;;
  esac
  chown -R bdimaio:bdimaio "$result_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

sed "s|\"status_file\": \"[^\"]*\"|\"status_file\": \"$temporary_root/status.json\"|" \
  "$original_config" > "$temporary_root/daemon.conf"
sed "s/\"delay\": 576/\"delay\": $sink_delay/g" "$original_status" > "$temporary_root/status.json"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); keys=("name","io","delay","use_sdp","source","sdp","ignore_refclk_gmid","map"); json.dump({k:d["sinks"][int(sys.argv[3])][k] for k in keys},open(sys.argv[2],"w"))' \
  "$temporary_root/status.json" "$temporary_root/sink-0.json" 0
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); keys=("name","io","delay","use_sdp","source","sdp","ignore_refclk_gmid","map"); json.dump({k:d["sinks"][int(sys.argv[3])][k] for k in keys},open(sys.argv[2],"w"))' \
  "$temporary_root/status.json" "$temporary_root/sink-1.json" 1

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

timeout -k 5 -s INT "$candidate_seconds" "$bridge_binary" \
  --period "$period_frames" \
  --buffer "$buffer_frames" \
  --ring "$ring_frames" \
  --target "$target_frames" \
  --playback-prime "$playback_prime_frames" \
  --prime-trim "$prime_trim" \
  --tx-playback-prime "$tx_playback_prime_frames" \
  --rx-playback-prime "$rx_playback_prime_frames" \
  --ravenna-playback-buffer "$ravenna_playback_buffer_frames" \
  --usb-pitch-servo "$usb_pitch_servo" \
  --tx-depth "$tx_depth_frames" \
  --rx-depth "$rx_depth_frames" \
  --level-gain "$level_gain" \
  --align-start "$align_start" \
  --align-offset-us "$align_offset_us" \
  --align-tx-trigger "$align_tx_trigger" \
  --align-tx-offset-us "$align_tx_offset_us" \
  --align-tx-prime "$align_tx_prime" \
  --zero-run-detect "$zero_run_detect" \
  --priority 90 \
  --seconds "$candidate_seconds" \
  > "$result_dir/bridge.log" 2>&1 &
bridge_pid=$!

sleep 4
if ! kill -0 "$bridge_pid" 2>/dev/null; then
  echo "Phase 4 bridge exited during startup" >&2
  exit 31
fi
if ! grep -q '^NEGOTIATED ' "$result_dir/bridge.log"; then
  echo "Phase 4 bridge did not report negotiated ALSA parameters" >&2
  exit 32
fi
if grep -Eq '^BRIDGE .*tx_restarts=[1-9][0-9]*|^BRIDGE .*rx_restarts=[1-9][0-9]*' \
    "$result_dir/bridge.log"; then
  echo "Phase 4 bridge restarted an ALSA direction during startup" >&2
  exit 33
fi

{
  echo "result_dir=$result_dir"
  echo "period_frames=$period_frames"
  echo "buffer_frames=$buffer_frames"
  echo "ring_frames=$ring_frames"
  echo "target_frames=$target_frames"
  echo "playback_prime_frames=$playback_prime_frames"
  echo "prime_trim=$prime_trim"
  echo "tx_playback_prime_frames=$tx_playback_prime_frames"
  echo "rx_playback_prime_frames=$rx_playback_prime_frames"
  echo "sink_delay=$sink_delay"
  echo "usb_pitch_servo=$usb_pitch_servo"
  echo "tx_depth_frames=$tx_depth_frames"
  echo "rx_depth_frames=$rx_depth_frames"
  echo "level_gain=$level_gain"
  echo "align_start=$align_start"
  echo "align_offset_us=$align_offset_us"
  echo "align_tx_trigger=$align_tx_trigger"
  echo "align_tx_offset_us=$align_tx_offset_us"
  echo "align_tx_prime=$align_tx_prime"
  echo "zero_run_detect=$zero_run_detect"
  echo "candidate_seconds=$candidate_seconds"
  echo "bridge_sha256=$expected_bridge_sha256"
} > "$result_dir/metadata.txt"
echo "$result_dir" > "$ready_file"
echo "READY result_dir=$result_dir"

while kill -0 "$bridge_pid" 2>/dev/null; do
  if grep -Eq '^BRIDGE .*tx_restarts=[1-9][0-9]*|^BRIDGE .*rx_restarts=[1-9][0-9]*' \
      "$result_dir/bridge.log"; then
    echo "Phase 4 bridge restarted an ALSA direction during the candidate" >&2
    exit 33
  fi
  sleep 1
done

set +e
wait "$bridge_pid"
bridge_status=$?
set -e
bridge_pid=
case "$bridge_status" in
  0|124|130|143) ;;
  *)
    echo "Phase 4 bridge failed with status $bridge_status" >&2
    exit 34
    ;;
esac
if grep -Eqi 'fatal:|xrun|overrun|underrun|broken pipe|restart[^s]' "$result_dir/bridge.log"; then
  echo "Phase 4 bridge log contains a failure marker" >&2
  exit 35
fi
if ! grep -Eq '^SUMMARY .*"tx_restarts":0,"rx_restarts":0' "$result_dir/bridge.log"; then
  echo "Phase 4 bridge did not finish with zero direction restarts" >&2
  exit 36
fi
if [ "$(sha256sum "$original_config" | awk '{print $1}')" != "$original_config_sha256" ] ||
   [ "$(sha256sum "$original_status" | awk '{print $1}')" != "$original_status_sha256" ]; then
  echo "protected AES67 prototype config changed unexpectedly" >&2
  exit 37
fi
if [ "$(cat /sys/class/udc/*/state)" != configured ] ||
   [ "$(cat /sys/class/udc/*/current_speed)" != high-speed ] ||
   [ "$(systemctl is-active usb-16x16.service)" != active ]; then
  echo "protected USB baseline failed during Phase 4 candidate" >&2
  exit 38
fi

echo "Phase 4 candidate completed cleanly"
