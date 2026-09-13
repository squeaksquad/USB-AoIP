#!/bin/bash
# A Phase 4 candidate run with the DSP stage loaded.
#
# Copied from run-phase4-candidate-safe.sh and changed in four places: the
# bridge binary and its pinned hash point at the candidate build rather than
# the installed one, a DSP coefficient artifact is pinned and passed to it, the
# bridge arguments are the accepted profile's own list taken verbatim from the
# supervisor's journal, and the results land under a distinct name.
#
# Nothing installed is touched. The accepted binary stays at
# /usr/local/libexec/usb16x16-rt-bridge, the supervisor still pins its hash,
# and rolling this back is not running it again. The daemon and module
# lifecycle is the proven one, unchanged.
#
# Usage: run-dsp-candidate-safe.sh [SECONDS] [DSP_PRESET|none]
#
# "none" runs the same binary with no --dsp-preset at all, which is the direct
# control: the stage is absent rather than loaded and bypassed, and it is the
# arm that shows what the candidate binary costs when nothing is filtering.
# Both arms therefore differ in exactly one argument.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root with sudo" >&2
  exit 2
fi

work_root=/home/bdimaio/usb-16x16-work
source_root="$work_root/aes67-daemon-src"
daemon_binary="$source_root/build-daemon/aes67-daemon"
module_binary="$work_root/aes67-source/ravenna-alsa-lkm-v2.1/driver/MergingRavennaALSA.ko"
bridge_binary=$work_root/dsp-verify/bridge-build/usb16x16-rt-bridge
original_config="$source_root/runtime/daemon-eth0.conf"
original_status="$source_root/runtime/status.json"
expected_daemon_sha256=e31ba2c44cdf07fd6ee0aef7d9a8457bfdd36321cc0407a35275e842b4577416
expected_module_sha256=f65a49558a0f8f16efbbe7afa45464d41529faacfcb1a838e897f99d9649604e
# The candidate build of 2026-09-10: the accepted 05f37bd9 source plus the DSP
# stage, wired into usb-to-ravenna only.
expected_bridge_sha256=406699bd4cf5763defb3560dca3d447d1dd2e8928dc370a643f1a080be026c88
# The compiled presets this wrapper will run. Pinned like every other artifact:
# a run that filtered something other than what was recorded would be worse
# than no run. Two are accepted, because the battery needs both:
#
#   loaded       16 outputs, 256 bands, 26 crossovers -- what the stage costs
#   transparent  the same 256 bands at 0.01 dB and no crossovers -- what the
#                stage does to latency, which cannot be asked of `loaded` at
#                all, since its 80 Hz high-pass means the impulse the harness
#                correlates against is no longer in the signal
expected_dsp_sha256_list="2b6baa0484a7d9a7d7a39f189d772a6864a473163c6e8098723954b652bb456c ad69598473691bffdd0808d79d4ff37f4d46ef9f0fa2b34b5fa1f3152b9bbeb9"
expected_gmid=00-1D-C1-FF-FE-1D-27-DC

# Only two arguments. Everything below is the accepted profile as a constant:
# this wrapper exists to run that one operating point with and without the DSP
# stage, and a positional knob would only let a run drift off it silently. It
# also means $2 is the preset and nothing else -- it used to be the preset AND
# period_frames, so "none" failed the unsigned-integer check.
candidate_seconds=${1:-360}
dsp_preset=${2:-$work_root/dsp-verify/loaded.dsp}
period_frames=48
buffer_frames=192
ring_frames=768
target_frames=48
# Frames primed into the ALSA playback queue. Zero keeps the historical
# behaviour of priming the whole playback buffer. This is the ring/queue split
# knob; the elastic ring keeps target_frames as the jitter reservoir.
playback_prime_frames=96
# Discard the ring overshoot at prime time (0 or 1). The overshoot is otherwise
# permanent pipeline depth, because depth is conserved after priming.
prime_trim=0
# Per-direction prime overrides; 0 inherits playback_prime_frames. tx is
# usb-to-ravenna (RAVENNA playback), rx is ravenna-to-usb (USB playback).
tx_playback_prime_frames=192
rx_playback_prime_frames=120
# Buffer request for the RAVENNA playback PCM alone; 0 inherits buffer_frames.
# Lifts TX's queue-floor ceiling without moving the RAVENNA capture buffer.
ravenna_playback_buffer_frames=384
# AES67 sink playout delay in samples, applied to both sinks before the bridge
# primes. Changing it live after priming never reaches the bridge (sweep
# 022225Z), so the value the run starts with is the one that can matter.
sink_delay=103
# Phase 5 step 1: 1 steers the USB gadget pitch controls to the PTP rate and
# runs both converters at exactly 1.0 (bit transparent); 0 is the resampler.
usb_pitch_servo=1
# Mode 2 depth setpoints (ring plus playback queue, frames); 0 captures the
# depth at engagement. Only meaningful with usb_pitch_servo=2.
tx_depth_frames=0
rx_depth_frames=0
# Mode 2 level gain in ppm per frame of depth error, (0, 0.1]. 0.05 turns 20
# frames into 1 ppm; 0.01 sat in the 1 ppm quantisation dead zone (142307Z).
level_gain=0.05
# Aligned start (0 or 1): the bridge times eight RAVENNA capture wakeups,
# then re-prepares that capture align_offset_us after the last one, so the
# driver's reader phase (fixed at prepare, anywhere inside a 1 ms tick) is a
# constant instead of a per-session draw. Offset in microseconds, 0..10000;
# a non-default offset needs align_start=1.
align_start=1
align_offset_us=600
# Aligned TX trigger (0 or 1): the RAVENNA playback trigger, at start and at
# every TX recovery, waits for the next tick-grid point plus
# align_tx_offset_us on the grid the aligned start measured, so the trigger's
# phase inside a 1 ms tick (the last per-session draw, up to 48 frames on TX)
# is a constant. Needs align_start=1; a non-default offset needs
# align_tx_trigger=1.
align_tx_trigger=1
align_tx_offset_us=950
# Aligned TX prime (0 or 1): the prime waits for one more period of ring and
# drops from the ring's front the frames that make the front frame's age at
# the first tick after the trigger a constant. Needs align_tx_trigger=1.
align_tx_prime=1
# Zero-run detector (0 or 1): the bridge scans every block entering and
# leaving it for per-channel runs of exact zeros (8 to 480 frames) and logs
# each as a ZERORUN line naming its stage, so the 41-sample holes can be
# placed on the leg that makes them. Behaviour-free; off by default.
zero_run_detect=1
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$work_root/logs/phase4-dsp-candidate-$timestamp"
ready_file=/tmp/usb16x16-phase4-candidate.ready
temporary_root=
daemon_pid=
bridge_pid=
# Declared here, not at the watcher loop: the metadata block and the cleanup
# path both run before that loop, and set -u makes an unbound read fatal.
restarts_seen=0

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
if [ "$(sha256sum "$bridge_binary" | awk '{print $1}')" != "$expected_bridge_sha256" ]; then
  echo "candidate bridge hash mismatch" >&2
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

# The accepted profile's argument list, verbatim from the supervisor's journal
# of the running service. Held in one array so what is launched and what is
# recorded are the same thing by construction.
bridge_arguments=(
  --period 48 --buffer 192 --ring 768 --target 48
  --playback-prime 96 --prime-trim 0 --rx-prime-trim 1
  --tx-playback-prime 192 --rx-playback-prime 120
  --ravenna-playback-buffer 384
  --usb-pitch-servo 1 --tx-depth 0 --rx-depth 0 --level-gain 0.05
  --align-start 1 --align-offset-us 600
  --align-tx-trigger 1 --align-tx-offset-us 950 --align-tx-prime 1
  --align-rx-trigger 0 --align-rx-offset-us 600 --align-rx-prime 0
  --align-prime-age-margin-us 50
  --zero-run-detect 1 --impulse-trace 1
  --pitch-seed 0 --level-shift 0
  --priority 90
  --seconds "$candidate_seconds"
)
if [ "$dsp_preset" != none ]; then
  bridge_arguments+=(--dsp-preset "$dsp_preset")
  # USB16X16_DSP_LIVE=1 (LIVE_COEFFICIENTS_DESIGN.md step 3): the candidate
  # polls $result_dir/dsp-live.dsp and answers on dsp-live.status, so a swap
  # can be driven from the Mac during the run by copying an artifact of the
  # same shape into place (write to a temporary name, then mv: the bridge
  # reads whole files only after a rename).
  if [ "${USB16X16_DSP_LIVE:-0}" = 1 ]; then
    bridge_arguments+=(--dsp-live-file "$result_dir/dsp-live.dsp" --dsp-live-status "$result_dir/dsp-live.status")
  fi
fi
timeout -k 5 -s INT "$candidate_seconds" "$bridge_binary" "${bridge_arguments[@]}" \
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

# The arguments the bridge was actually given, not the positional variables.
# This wrapper hardcodes the accepted profile, so echoing the positionals would
# record an operating point that was never run -- period 96 and align_start 0
# when the bridge ran 48 and 1. The first run of this wrapper
# (20260910T180122Z) wrote exactly that misleading file before this was fixed;
# read its bridge.log, which carries the real arguments, not its metadata.
{
  echo "result_dir=$result_dir"
  echo "sink_delay=$sink_delay"
  echo "candidate_seconds=$candidate_seconds"
  echo "dsp_preset=$dsp_preset"
  echo "dsp_sha256=$([ "$dsp_preset" = none ] && echo none || sha256sum "$dsp_preset" | awk '{print $1}')"
  echo "dsp_live=${USB16X16_DSP_LIVE:-0}"
  echo "bridge_binary=$bridge_binary"
  echo "bridge_sha256=$(sha256sum "$bridge_binary" | awk '{print $1}')"
  echo "bridge_arguments=${bridge_arguments[*]}"
} > "$result_dir/metadata.txt"
echo "$result_dir" > "$ready_file"
echo "READY result_dir=$result_dir"

# A direction restart is counted, not fatal.
#
# The wrapper this was copied from aborts on the first one, which is right for
# an unattended stability run: nothing else is touching the device, so a restart
# means the operating point is wrong. Under the measurement harness it is not
# right. The harness opens and closes the CoreAudio device for every readiness
# probe, every close stops the gadget PCM, and the bridge re-primes -- the
# device-close behaviour this project has recorded since the Pro Tools crash.
# Two harness-driven runs on 2026-09-10 died at 15 s and 21 s on exactly that,
# in different directions, one of them with nothing at all touching the Pi.
#
# So this counts restarts and lets the run finish, which is what the repo's own
# rule says ("a bridge RECOVER during a service measurement is counted, not
# fatal") and what the service does when the accepted figures are taken against
# it. A runaway is still fatal: more than restart_limit means something other
# than a probe is wrong.
restart_limit=${USB16X16_DSP_RESTART_LIMIT:-8}
while kill -0 "$bridge_pid" 2>/dev/null; do
  restarts_seen=$(awk '/^BRIDGE /{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^tx_restarts=/) { split($i, a, "="); tx = a[2] }
        if ($i ~ /^rx_restarts=/) { split($i, a, "="); rx = a[2] }
      }
    } END { print tx + rx + 0 }' "$result_dir/bridge.log" 2>/dev/null)
  restarts_seen=${restarts_seen:-0}
  if [ "$restarts_seen" -gt "$restart_limit" ]; then
    echo "Phase 4 bridge restarted an ALSA direction $restarts_seen times, over the limit of $restart_limit" >&2
    exit 33
  fi
  sleep 1
done
echo "direction_restarts=$restarts_seen" >> "$result_dir/metadata.txt"
if [ "$restarts_seen" -gt 0 ]; then
  echo "note: $restarts_seen ALSA direction restart(s) during the candidate, counted not fatal" >&2
fi

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
# The same marker check, minus the RECOVER lines themselves.
#
# A counted RECOVER line carries "XRUN" and "Broken pipe" by construction, so
# leaving them in would fail every run that the watcher above deliberately let
# finish -- which is what happened on 2026-09-10: six counted restarts, a valid
# measurement, and exit 35 anyway. Markers anywhere else still fail the run.
if grep -v '^RECOVER ' "$result_dir/bridge.log" |
   grep -Eqi 'fatal:|xrun|overrun|underrun|broken pipe|restart[^s]'; then
  echo "Phase 4 bridge log contains a failure marker outside a counted RECOVER" >&2
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
