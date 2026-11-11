#!/bin/bash
set -euo pipefail

# Brings the AES67 bridge up and HOLDS it so the Ferrofish can be routed
# interactively. Same stack as the measurement candidate, but it does not run
# for a fixed measurement window and produces no latency number.
#
# The production daemon config and status.json are never modified: the daemon
# runs against a temporary copy with only status_file redirected. Sink and
# source definitions are byte-identical to the saved ones.
#
# Press Ctrl+C when routing is done. Cleanup stops both audio directions and
# the daemon, unloads the RAVENNA module, and verifies the protected USB
# baseline.

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
hold_seconds=${USB16X16_HOLD_SECONDS:-3600}
period_frames=${USB16X16_PERIOD_FRAMES:-96}
buffer_frames=${USB16X16_BUFFER_FRAMES:-288}
target_latency_usec=${USB16X16_TARGET_USEC:-5000}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$work_root/logs/bridge-hold-$timestamp"
temporary_root=
daemon_pid=
rx_pid=
tx_pid=

if ! [[ "$hold_seconds" =~ ^[0-9]+$ ]] ||
   [ "$hold_seconds" -lt 60 ] ||
   [ "$hold_seconds" -gt 21600 ]; then
  echo "hold duration must be 60..21600 seconds" >&2
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
temporary_root=$(mktemp -d /tmp/usb16x16-bridge-hold.XXXXXX)
mkdir -p "$result_dir"

cleanup() {
  set +e
  echo ""
  echo "stopping bridge ..."
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
    /tmp/usb16x16-bridge-hold.*) rm -rf "$temporary_root" ;;
  esac
  chown -R bdimaio:bdimaio "$result_dir" 2>/dev/null
  if [ "$(sha256sum "$original_config" | awk '{print $1}')" = "$original_config_sha256" ] &&
     [ "$(sha256sum "$original_status" | awk '{print $1}')" = "$original_status_sha256" ]; then
    echo "production daemon config unchanged"
  else
    echo "WARNING: production daemon config changed unexpectedly" >&2
  fi
  echo "usb service: $(systemctl is-active usb-16x16.service)"
  echo "udc: $(cat /sys/class/udc/*/state)/$(cat /sys/class/udc/*/current_speed)"
  echo "logs: $result_dir"
}
trap cleanup EXIT INT TERM HUP

sed "s|\"status_file\": \"[^\"]*\"|\"status_file\": \"$temporary_root/status.json\"|" \
  "$original_config" > "$temporary_root/daemon.conf"
cp "$original_status" "$temporary_root/status.json"

if ! grep -q "\"status_file\": \"$temporary_root/status.json\"" "$temporary_root/daemon.conf"; then
  echo "temporary configuration verification failed" >&2
  exit 27
fi

for sink_id in 0 1; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); keys=("name","io","delay","use_sdp","source","sdp","ignore_refclk_gmid","map"); json.dump({k:d["sinks"][int(sys.argv[3])][k] for k in keys},open(sys.argv[2],"w"))' \
    "$temporary_root/status.json" "$temporary_root/sink-$sink_id.json" "$sink_id"
done

echo "loading RAVENNA module ..."
/usr/sbin/insmod "$module_binary"
echo "starting AES67 daemon ..."
"$daemon_binary" -c "$temporary_root/daemon.conf" > "$result_dir/daemon.log" 2>&1 &
daemon_pid=$!

api_ready=0
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:8080/api/ptp/status > "$result_dir/ptp-status.json" 2>/dev/null; then
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
echo "daemon API ready on port 8080"

echo "waiting for PTP lock to $expected_gmid ..."
ptp_locked=0
for attempt in $(seq 1 90); do
  curl -fsS --max-time 3 http://127.0.0.1:8080/api/ptp/status > "$result_dir/ptp-status.json" 2>/dev/null
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
echo "PTP locked"

# Reapply the saved sinks after lock: the daemon rejects strict-GMID sinks
# loaded before PTP is locked and does not retry on its own.
for sink_id in 0 1; do
  curl -fsS -X PUT "http://127.0.0.1:8080/api/sink/$sink_id" \
    -H 'Content-Type: application/json' \
    --data-binary "@$temporary_root/sink-$sink_id.json" \
    > "$result_dir/sink-$sink_id-put.json" || true
done
echo "receive sinks reapplied"

echo "starting audio directions ..."
alsaloop \
  -C plughw:CARD=RAVENNA,DEV=0 \
  -P plughw:CARD=UAC2Gadget,DEV=0 \
  -r 48000 -c 16 -f S32_LE \
  -S samplerate -A sincfastest \
  --tlatency "$target_latency_usec" --period "$period_frames" --buffer "$buffer_frames" \
  -v > "$result_dir/aes67-to-usb.log" 2>&1 &
rx_pid=$!
sleep 1
alsaloop \
  -C plughw:CARD=UAC2Gadget,DEV=0 \
  -P plughw:CARD=RAVENNA,DEV=0 \
  -r 48000 -c 16 -f S32_LE \
  -S samplerate -A sincfastest \
  --tlatency "$target_latency_usec" --period "$period_frames" --buffer "$buffer_frames" \
  -v > "$result_dir/usb-to-aes67.log" 2>&1 &
tx_pid=$!

sleep 4
if ! kill -0 "$rx_pid" 2>/dev/null || ! kill -0 "$tx_pid" 2>/dev/null; then
  echo "one or both audio directions exited during startup" >&2
  exit 30
fi

echo ""
echo "=============================================================="
echo " BRIDGE IS LIVE - the Pi is now transmitting and discoverable."
echo " Route the Ferrofish, then press Ctrl+C here when finished."
echo "=============================================================="
echo ""

elapsed=0
while [ "$elapsed" -lt "$hold_seconds" ]; do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    echo "daemon exited unexpectedly" >&2
    exit 31
  fi
  if ! kill -0 "$rx_pid" 2>/dev/null || ! kill -0 "$tx_pid" 2>/dev/null; then
    echo "an audio direction exited unexpectedly" >&2
    exit 32
  fi
  line="[$(date -u +%H:%M:%SZ)]"
  for sink_id in 0 1; do
    if curl -fsS --max-time 3 "http://127.0.0.1:8080/api/sink/status/$sink_id" \
        > "$result_dir/sink-$sink_id-status.json" 2>/dev/null; then
      if grep -Eq '"receiving_rtp_packet"[[:space:]]*:[[:space:]]*true' \
          "$result_dir/sink-$sink_id-status.json"; then
        line="$line  sink$sink_id=RECEIVING"
      else
        line="$line  sink$sink_id=no-rtp"
      fi
    else
      line="$line  sink$sink_id=?"
    fi
  done
  echo "$line"
  sleep 15
  elapsed=$((elapsed + 15))
done

echo "hold window elapsed"
