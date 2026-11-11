#!/bin/bash
set -euo pipefail

# Phase 6 scheduler wake-up latency measurement.
#
# Answers one question: is scheduling latency anywhere near the ALSA period
# time? If maximum wake-up latency sits well below the period, scheduling is
# not the constraint and a PREEMPT_RT kernel is not justified. That matters
# here because the protected USB module and the RAVENNA prototype module are
# both built against 6.18.34+rpt-rpi-2712 and would need rebuilding and
# revalidating for any kernel change.
#
# Run it twice: once idle, once with the bridge live. The loaded number is the
# one that decides anything.

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root with sudo" >&2
  exit 2
fi

work_root=/home/bdimaio/usb-16x16-work
cyclictest_binary="$work_root/deps/rt-tests/usr/bin/cyclictest"
[ -x "$cyclictest_binary" ] || cyclictest_binary=$(command -v cyclictest || true)
duration_seconds=${USB16X16_CYCLICTEST_SECONDS:-300}
interval_usec=${USB16X16_CYCLICTEST_INTERVAL:-250}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$work_root/logs/cyclictest-$timestamp"

if [ -z "$cyclictest_binary" ] || [ ! -x "$cyclictest_binary" ]; then
  echo "cyclictest not found; extract rt-tests to $work_root/deps/rt-tests" >&2
  exit 3
fi
if ! [[ "$duration_seconds" =~ ^[0-9]+$ ]] || [ "$duration_seconds" -lt 30 ] || [ "$duration_seconds" -gt 1800 ]; then
  echo "duration must be 30..1800 seconds" >&2
  exit 10
fi

mkdir -p "$result_dir"

# Record what was running, because an idle number and a loaded number mean
# entirely different things.
bridge_state=idle
if pgrep -x aes67-daemon >/dev/null && pgrep -x alsaloop >/dev/null; then
  bridge_state=bridge-live
fi

{
  echo "timestamp=$timestamp"
  echo "kernel=$(uname -r)"
  echo "bridge_state=$bridge_state"
  echo "alsaloop_processes=$(pgrep -c -x alsaloop 2>/dev/null || echo 0)"
  echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  echo "duration_seconds=$duration_seconds"
  echo "interval_usec=$interval_usec"
  echo "cyclictest=$cyclictest_binary"
  echo "temp=$(vcgencmd measure_temp 2>/dev/null || echo unknown)"
  echo "throttled=$(vcgencmd get_throttled 2>/dev/null || echo unknown)"
} > "$result_dir/metadata.txt"

echo "running cyclictest for ${duration_seconds}s (${bridge_state}) ..."
"$cyclictest_binary" \
  --mlockall --smp --priority=99 \
  --interval="$interval_usec" --distance=0 \
  --duration="${duration_seconds}" \
  --histogram=2000 --quiet \
  > "$result_dir/cyclictest.txt" 2>&1 || true

# The histogram tail carries the Min/Avg/Max summary lines.
grep -E "^# (Min|Avg|Max|Total|Histogram)" "$result_dir/cyclictest.txt" \
  > "$result_dir/summary.txt" 2>/dev/null || true
tail -5 "$result_dir/cyclictest.txt" >> "$result_dir/summary.txt" 2>/dev/null || true

{
  echo "temp_after=$(vcgencmd measure_temp 2>/dev/null || echo unknown)"
  echo "throttled_after=$(vcgencmd get_throttled 2>/dev/null || echo unknown)"
} >> "$result_dir/metadata.txt"

chown -R bdimaio:bdimaio "$result_dir" 2>/dev/null || true

echo "result_dir=$result_dir"
echo "--- summary ---"
cat "$result_dir/summary.txt" 2>/dev/null

# Reference points the number has to be read against.
echo "--- reference period times at 48 kHz ---"
echo "  128 frames = 2.667 ms   144 frames = 3.000 ms"
echo "  384 frames = 8.000 ms   576 frames = 12.000 ms"
