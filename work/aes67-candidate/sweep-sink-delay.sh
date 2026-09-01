#!/bin/zsh
set -uo pipefail

# Phase 2 one-variable sweep of the AES67 sink playout delay against the full
# Ferrofish round trip. Buffering is left at the driver default, which measured
# 44.792 ms at delay 576. Each point is a separate measure-aes67-roundtrip.sh
# run; this only sequences them and tabulates the results.

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
candidate_seconds=${USB16X16_CANDIDATE_SECONDS:-180}
coreaudio_frames=${USB16X16_COREAUDIO_FRAMES:-64}
impulse_count=${USB16X16_IMPULSES:-40}

if (( $# == 0 )); then
    delays=(288 144 96 48)
else
    delays=("$@")
fi

summary_lines=()
failures=0

for sink_delay in "${delays[@]}"; do
    print -r -- ""
    print -r -- "############ sink delay $sink_delay ############"
    point_log=$(mktemp -t usb16x16-sweep)
    USB16X16_SINK_DELAY="$sink_delay" \
        "$script_dir/measure-aes67-roundtrip.sh" \
        "$candidate_seconds" "$coreaudio_frames" "$impulse_count" 2>&1 | tee "$point_log"
    point_status=${pipestatus[1]}

    result_path=$(grep -m1 '^result=' "$point_log" | sed 's/^result=//')
    if [[ -n "$result_path" && -s "$result_path" ]]; then
        line=$(USB16X16_RESULT="$result_path" USB16X16_DELAY="$sink_delay" /usr/bin/python3 <<'PYEOF'
import json
import os

probe = json.load(open(os.environ["USB16X16_RESULT"]))
correlation = probe["correlation"]
statistics = correlation["statistics"]
delays = correlation["perImpulseDelaySamples"]
spread = max(delays) - min(delays)
trustworthy = probe["capturedPeak"] >= 0.01 and spread <= 2
print(
    "%-6s %-10.3f %-10.3f %-8.4f %-8d %-10.6f %s"
    % (
        os.environ["USB16X16_DELAY"],
        statistics["medianMilliseconds"],
        statistics["p99Milliseconds"],
        correlation["score"],
        spread,
        probe["capturedPeak"],
        "ok" if trustworthy else "SUSPECT",
    )
)
PYEOF
)
        summary_lines+=("$line")
    else
        summary_lines+=("$(printf '%-6s no measurement (exit %s)' "$sink_delay" "$point_status")")
        (( failures += 1 ))
    fi
    rm -f "$point_log"
done

print -r -- ""
print -r -- "================ sink delay sweep ================"
print -r -- "delay  median_ms  p99_ms     score    spread   peak       verdict"
for line in "${summary_lines[@]}"; do
    print -r -- "$line"
done
print -r -- "=================================================="
print -r -- "failures=$failures"
exit "$failures"
