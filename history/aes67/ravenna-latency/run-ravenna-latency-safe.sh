#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root with sudo" >&2
  exit 2
fi

source_root=/home/bdimaio/usb-16x16-work/aes67-daemon-src
daemon_binary="$source_root/build-daemon/aes67-daemon"
module_binary=/home/bdimaio/usb-16x16-work/aes67-source/ravenna-alsa-lkm-v2.1/driver/MergingRavennaALSA.ko
expected_module_sha256=f65a49558a0f8f16efbbe7afa45464d41529faacfcb1a838e897f99d9649604e
alsa_dev_root=/home/bdimaio/usb-16x16-work/deps/libasound2-dev
alsa_runtime=/usr/lib/aarch64-linux-gnu/libasound.so.2.0.0
duration_seconds=${USB16X16_RAVENNA_TEST_SECONDS:-10}
sink_delays_text=${USB16X16_RAVENNA_SINK_DELAYS:-576}
sample_format=S24_3LE
sample_rate=48000
channels=16
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="/home/bdimaio/usb-16x16-work/logs/ravenna-latency-$timestamp"
temporary_root=

if [ "$#" -eq 0 ]; then
  frame_sizes=(384 192 144 96)
else
  frame_sizes=("$@")
fi
read -r -a sink_delays <<< "$sink_delays_text"

for sink_delay in "${sink_delays[@]}"; do
  case "$sink_delay" in
    576|288|144|96|48) ;;
    *)
      echo "unsupported reconnaissance sink delay: $sink_delay" >&2
      exit 19
      ;;
  esac
done

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

if [ -x /usr/bin/pulseaudio ]; then
  echo "refusing to start: upstream test would alter PulseAudio user state" >&2
  exit 22
fi

if [ ! -x "$daemon_binary" ]; then
  echo "missing daemon: $daemon_binary" >&2
  exit 23
fi
if [ ! -r "$module_binary" ]; then
  echo "missing module: $module_binary" >&2
  exit 24
fi
if [ ! -r "$alsa_dev_root/usr/include/alsa/asoundlib.h" ] ||
   [ ! -r "$alsa_runtime" ]; then
  echo "missing private ALSA development headers or system runtime library" >&2
  exit 29
fi

actual_module_sha256=$(sha256sum "$module_binary" | awk '{print $1}')
if [ "$actual_module_sha256" != "$expected_module_sha256" ]; then
  echo "RAVENNA module hash mismatch" >&2
  exit 25
fi

original_igmp=$(/usr/sbin/sysctl -n net.ipv4.igmp_max_memberships)
original_perf=$(/usr/sbin/sysctl -n kernel.perf_cpu_time_max_percent)
original_rt=$(/usr/sbin/sysctl -n kernel.sched_rt_runtime_us)
temporary_root=$(mktemp -d /tmp/usb16x16-ravenna-latency.XXXXXX)

cleanup() {
  set +e
  pkill -INT -x aes67-daemon
  pkill -INT -x ptp4l
  sleep 1
  pkill -TERM -x aes67-daemon
  pkill -TERM -x ptp4l
  for attempt in 1 2 3 4 5; do
    if ! lsmod | grep -q '^MergingRavennaALSA '; then
      break
    fi
    /usr/sbin/rmmod MergingRavennaALSA 2>/dev/null || true
    sleep 1
  done
  /usr/sbin/sysctl -q -w "net.ipv4.igmp_max_memberships=$original_igmp"
  /usr/sbin/sysctl -q -w "kernel.perf_cpu_time_max_percent=$original_perf"
  /usr/sbin/sysctl -q -w "kernel.sched_rt_runtime_us=$original_rt"
  case "$temporary_root" in
    /tmp/usb16x16-ravenna-latency.*) rm -rf "$temporary_root" ;;
  esac
  chown -R bdimaio:bdimaio "$result_dir" 2>/dev/null
  if lsmod | grep -q '^MergingRavennaALSA '; then
    echo "cleanup failed: MergingRavennaALSA remains loaded" >&2
    return 31
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$result_dir"
cp -a "$source_root/test" "$temporary_root/test"
cp "$source_root/run_latency_test.sh" "$temporary_root/run_latency_test.base.sh"
mkdir -p "$temporary_root/daemon"
mkdir -p "$temporary_root/3rdparty/ravenna-alsa-lkm/driver"
ln -s "$daemon_binary" "$temporary_root/daemon/aes67-daemon"
ln -s "$module_binary" "$temporary_root/3rdparty/ravenna-alsa-lkm/driver/MergingRavennaALSA.ko"

make -C "$temporary_root/test" \
  CXXFLAGS="-I$alsa_dev_root/usr/include" \
  LIBS="-lpthread $alsa_runtime"

cd "$temporary_root"
for sink_delay in "${sink_delays[@]}"; do
  sed "s/\"delay\": 576,/\"delay\": $sink_delay,/" \
    run_latency_test.base.sh > run_latency_test.sh
  chmod 755 run_latency_test.sh
  if ! grep -q "\"delay\": $sink_delay," run_latency_test.sh; then
    echo "failed to apply sink delay=$sink_delay to temporary test script" >&2
    exit 32
  fi

  for frames in "${frame_sizes[@]}"; do
    case "$frames" in
      384|192|144|96) ;;
      *)
        echo "unsupported reconnaissance frame size: $frames" >&2
        exit 26
        ;;
    esac

    log_path="$result_dir/ravenna-${frames}f-${sink_delay}d.log"
    echo "=== RAVENNA latency frames=$frames sink_delay=$sink_delay channels=$channels duration=$duration_seconds ===" | tee "$log_path"
    ./run_latency_test.sh \
      "$sample_format" \
      "$sample_rate" \
      "$channels" \
      "$duration_seconds" \
      "$frames" \
      2>&1 | tee -a "$log_path"

    if ! grep -q '^End to end latency:' "$log_path" ||
       ! grep -q '^Success$' "$log_path" ||
       grep -Eq '^Failure$|state[[:space:]]*:[[:space:]]*XRUN' "$log_path"; then
      echo "latency test did not complete cleanly for frames=$frames sink_delay=$sink_delay" >&2
      exit 30
    fi

    if pgrep -x ptp4l >/dev/null || pgrep -x aes67-daemon >/dev/null; then
      echo "upstream cleanup left a process running" >&2
      exit 27
    fi
    if [ "$(cat /sys/class/udc/*/state)" != configured ] ||
       [ "$(cat /sys/class/udc/*/current_speed)" != high-speed ] ||
       [ "$(systemctl is-active usb-16x16.service)" != active ]; then
      echo "protected USB baseline failed after frames=$frames sink_delay=$sink_delay" >&2
      exit 28
    fi
  done
done

echo "result_dir=$result_dir"
