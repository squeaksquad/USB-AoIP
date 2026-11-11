#!/bin/zsh
set -u

script_dir=${0:A:h}
coreaudio_frames=${USB16X16_COREAUDIO_FRAMES:-64}
impulse_count=${USB16X16_IMPULSE_COUNT:-20}
maximum_lag_ms=${USB16X16_MAXIMUM_LAG_MS:-500}
if (( $# == 0 )); then
    latencies=(80000 40000 20000 10000 5000)
else
    latencies=("$@")
fi
failures=0

for loopback_usec in "${latencies[@]}"; do
    print -r -- "=== alsaloop_target_usec=$loopback_usec coreaudio_frames=$coreaudio_frames ==="
    if ! "$script_dir/measure-usb-only.sh" \
        "$loopback_usec" \
        "$coreaudio_frames" \
        "$impulse_count" \
        "$maximum_lag_ms"; then
        print -ru2 -- "FAILED alsaloop_target_usec=$loopback_usec"
        (( failures += 1 ))
    fi
done

exit "$failures"
