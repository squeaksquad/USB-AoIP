#!/bin/bash
set -euo pipefail

# Pi-side AES67 self-loop candidate.
#
# Identical to run-aes67-candidate-safe.sh except that the daemon subscribes to
# its own transmit streams instead of the Ferrofish. This closes the round trip
# on the Pi and removes the Ferrofish as a variable:
#
#   USB capture -> RAVENNA playback -> source 0/1 -> multicast
#                                   -> sink 0/1 -> RAVENNA capture -> USB playback
#
# Self-subscription is the same technique the upstream run_latency_test.sh uses,
# so multicast self-reception is already proven on this hardware.
#
# The saved production config is never modified. Sinks are created at runtime
# from the daemon's own published source SDPs, so no SDP text is hand-written
# and the strict-GMID startup race cannot occur.

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root with sudo" >&2
  exit 2
fi

work_root=/home/bdimaio/usb-16x16-work
source_root="$work_root/aes67-daemon-src"
daemon_binary="$source_root/build-daemon/aes67-daemon"
module_binary="$work_root/aes67-source/ravenna-alsa-lkm-v2.1/driver/MergingRavennaALSA.ko"
original_config="$source_root/runtime/daemon-eth0.conf"
original_status="$source_root/runtime/status.json"
expected_daemon_sha256=e31ba2c44cdf07fd6ee0aef7d9a8457bfdd36321cc0407a35275e842b4577416
expected_module_sha256=f65a49558a0f8f16efbbe7afa45464d41529faacfcb1a838e897f99d9649604e
expected_gmid=00-1D-C1-FF-FE-1D-27-DC
candidate_seconds=${USB16X16_CANDIDATE_SECONDS:-180}
period_frames=${USB16X16_PERIOD_FRAMES:-96}
buffer_frames=${USB16X16_BUFFER_FRAMES:-288}
target_latency_usec=${USB16X16_TARGET_USEC:-5000}
sink_delay=${USB16X16_SINK_DELAY:-48}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$work_root/logs/selfloop-$timestamp"
ready_file=/tmp/usb16x16-selfloop.ready
temporary_root=
daemon_pid=
rx_pid=
tx_pid=

if ! [[ "$candidate_seconds" =~ ^[0-9]+$ ]] ||
   [ "$candidate_seconds" -lt 30 ] ||
   [ "$candidate_seconds" -gt 900 ]; then
  echo "candidate duration must be 30..900 seconds" >&2
  exit 10
fi

for process_name in ptp4l aes67-daemon alsaloop; do
  if pgrep -x "$process_name" >/dev/null; then
    echo "refusing to start: $process_name is already running" >&2
    exit 20
  fi
done
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

for required_path in "$daemon_binary" "$module_binary" "$original_config" "$original_status"; do
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

original_config_sha256=$(sha256sum "$original_config" | awk '{print $1}')
original_status_sha256=$(sha256sum "$original_status" | awk '{print $1}')
temporary_root=$(mktemp -d /tmp/usb16x16-selfloop.XXXXXX)
mkdir -p "$result_dir"
rm -f "$ready_file"

cleanup() {
  set +e
  rm -f "$ready_file"
  for pid in "$tx_pid" "$rx_pid"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -INT "$pid"
    fi
  done
  sleep 1
  for pid in "$tx_pid" "$rx_pid"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid"
    fi
  done
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
    /tmp/usb16x16-selfloop.*) rm -rf "$temporary_root" ;;
  esac
  chown -R bdimaio:bdimaio "$result_dir" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

sed "s|\"status_file\": \"[^\"]*\"|\"status_file\": \"$temporary_root/status.json\"|" \
  "$original_config" > "$temporary_root/daemon.conf"

# Keep the validated transmit sources exactly as saved; start with no sinks so
# nothing is loaded before PTP lock. The self-loop sinks are created afterwards.
python3 -c '
import json, sys
saved = json.load(open(sys.argv[1]))
json.dump({"sources": saved["sources"], "sinks": []}, open(sys.argv[2], "w"), indent=1)
' "$original_status" "$temporary_root/status.json"

if ! grep -q "\"status_file\": \"$temporary_root/status.json\"" "$temporary_root/daemon.conf"; then
  echo "temporary self-loop configuration verification failed" >&2
  exit 27
fi

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

# Build each sink from the daemon's own published SDP for the matching source.
for sink_id in 0 1; do
  curl -fsS "http://127.0.0.1:8080/api/source/sdp/$sink_id" \
    > "$temporary_root/source-$sink_id.sdp"
  if [ ! -s "$temporary_root/source-$sink_id.sdp" ]; then
    echo "could not read published SDP for source $sink_id" >&2
    exit 35
  fi
  python3 -c '
import json, sys
sink_id = int(sys.argv[3])
sdp = open(sys.argv[1]).read()
base = sink_id * 8
json.dump({
    "name": "SELF RX %02d-%02d" % (base + 1, base + 8),
    "io": "Audio Device",
    "use_sdp": True,
    "source": "http://127.0.0.1:8080/api/source/sdp/%d" % sink_id,
    "sdp": sdp,
    "delay": int(sys.argv[4]),
    "ignore_refclk_gmid": True,
    "map": list(range(base, base + 8)),
}, open(sys.argv[2], "w"))
' "$temporary_root/source-$sink_id.sdp" "$temporary_root/sink-$sink_id.json" \
    "$sink_id" "$sink_delay"
  cp "$temporary_root/sink-$sink_id.json" "$result_dir/sink-$sink_id-request.json"
  curl -fsS -X PUT "http://127.0.0.1:8080/api/sink/$sink_id" \
    -H 'Content-Type: application/json' \
    --data-binary "@$temporary_root/sink-$sink_id.json" \
    > "$result_dir/sink-$sink_id-put.json"
done

timeout -k 5 -s INT "$candidate_seconds" alsaloop \
  -C plughw:CARD=RAVENNA,DEV=0 \
  -P plughw:CARD=UAC2Gadget,DEV=0 \
  -r 48000 -c 16 -f S32_LE \
  -S samplerate -A sincfastest \
  --tlatency "$target_latency_usec" --period "$period_frames" --buffer "$buffer_frames" \
  -s "$candidate_seconds" -v \
  > "$result_dir/aes67-to-usb.log" 2>&1 &
rx_pid=$!
sleep 1
timeout -k 5 -s INT "$candidate_seconds" alsaloop \
  -C plughw:CARD=UAC2Gadget,DEV=0 \
  -P plughw:CARD=RAVENNA,DEV=0 \
  -r 48000 -c 16 -f S32_LE \
  -S samplerate -A sincfastest \
  --tlatency "$target_latency_usec" --period "$period_frames" --buffer "$buffer_frames" \
  -s "$candidate_seconds" -v \
  > "$result_dir/usb-to-aes67.log" 2>&1 &
tx_pid=$!

sleep 4
if ! kill -0 "$rx_pid" 2>/dev/null || ! kill -0 "$tx_pid" 2>/dev/null; then
  echo "one or both candidate audio directions exited during startup" >&2
  exit 30
fi

# Sources transmit only once RAVENNA playback is streaming, so the self-loop can
# only be confirmed after the audio directions are up.
sleep 5
self_loop_ok=1
for sink_id in 0 1; do
  curl -fsS "http://127.0.0.1:8080/api/sink/status/$sink_id" \
    > "$result_dir/sink-$sink_id-status.json"
  if ! grep -Eq '"receiving_rtp_packet"[[:space:]]*:[[:space:]]*true' \
      "$result_dir/sink-$sink_id-status.json"; then
    echo "sink $sink_id is not receiving RTP: multicast self-reception failed" >&2
    self_loop_ok=0
  fi
  if grep -Eq '"all_muted"[[:space:]]*:[[:space:]]*true' \
      "$result_dir/sink-$sink_id-status.json"; then
    echo "sink $sink_id reports all_muted" >&2
    self_loop_ok=0
  fi
done
if [ "$self_loop_ok" -ne 1 ]; then
  echo "aborting before measurement: the AES67 self-loop did not establish" >&2
  exit 36
fi

{
  echo "result_dir=$result_dir"
  echo "mode=selfloop"
  echo "period_frames=$period_frames"
  echo "buffer_frames=$buffer_frames"
  echo "target_latency_usec=$target_latency_usec"
  echo "sink_delay=$sink_delay"
  echo "candidate_seconds=$candidate_seconds"
} > "$result_dir/metadata.txt"
echo "$result_dir" > "$ready_file"
echo "READY result_dir=$result_dir"

set +e
wait "$rx_pid"
rx_status=$?
wait "$tx_pid"
tx_status=$?
set -e
rx_pid=
tx_pid=

for status in "$rx_status" "$tx_status"; do
  case "$status" in
    0|124|130|143) ;;
    *)
      echo "candidate audio process failed: rx=$rx_status tx=$tx_status" >&2
      exit 31
      ;;
  esac
done
if grep -Eqi 'xrun|overrun|underrun|broken pipe|error|failure' \
  "$result_dir/aes67-to-usb.log" "$result_dir/usb-to-aes67.log"; then
  echo "candidate audio logs contain an error marker" >&2
  exit 32
fi
if [ "$(sha256sum "$original_config" | awk '{print $1}')" != "$original_config_sha256" ] ||
   [ "$(sha256sum "$original_status" | awk '{print $1}')" != "$original_status_sha256" ]; then
  echo "protected production prototype config changed unexpectedly" >&2
  exit 33
fi
if [ "$(cat /sys/class/udc/*/state)" != configured ] ||
   [ "$(cat /sys/class/udc/*/current_speed)" != high-speed ] ||
   [ "$(systemctl is-active usb-16x16.service)" != active ]; then
  echo "protected USB baseline failed during candidate run" >&2
  exit 34
fi

echo "self-loop candidate completed cleanly"
