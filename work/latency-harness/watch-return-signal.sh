#!/bin/zsh
set -uo pipefail

# Repeatedly fires the existing impulse harness through the live bridge and
# reports whether the signal is coming back, so the Ferrofish can be routed
# with immediate feedback. This adds no measurement method of its own: each
# iteration is one ordinary `measure` run.
#
# A real return locks every impulse to the same delay. Noise produces a
# scattered spread and a capture peak near the noise floor, so both the peak
# and the spread must pass before a lock is declared.

script_dir=${0:A:h}
app_binary="$script_dir/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
device=${USB16X16_DEVICE:-USB 16x16}
frames=${USB16X16_COREAUDIO_FRAMES:-64}
output_channel=${USB16X16_OUTPUT_CHANNEL:-1}
input_channel=${USB16X16_INPUT_CHANNEL:-1}
impulses=${USB16X16_IMPULSES:-12}
maximum_lag_ms=${USB16X16_MAXIMUM_LAG_MS:-200}
peak_threshold=${USB16X16_PEAK_THRESHOLD:-0.01}
spread_limit=${USB16X16_SPREAD_LIMIT:-2}
required_consecutive=${USB16X16_REQUIRED_CONSECUTIVE:-3}
duration_seconds=${1:-1200}

if (( maximum_lag_ms >= 250 )); then
    print -ru2 -- "maximum lag must remain below the 250 ms impulse interval"
    exit 2
fi

if [[ ! -x "$app_binary" ]]; then
    print -ru2 -- "missing harness app bundle: $app_binary"
    exit 2
fi

work_dir=$(mktemp -d -t usb16x16-watch)
trap 'rm -rf "$work_dir"' EXIT INT TERM

print -r -- "watching out ch$output_channel -> in ch$input_channel  (${impulses} impulses per burst)"
print -r -- "peak threshold ${peak_threshold}, delay spread limit ${spread_limit} samples"
print -r -- "press Ctrl+C to stop; window is ${duration_seconds}s"
print -r -- ""

started=$SECONDS
locked_once=0
consecutive_locks=0
iteration=0

while (( SECONDS - started < duration_seconds )); do
    (( iteration += 1 ))
    probe="$work_dir/probe.json"
    rm -f "$probe"
    "$app_binary" measure \
        --device "$device" \
        --buffer-frames "$frames" \
        --input-channel "$input_channel" \
        --output-channel "$output_channel" \
        --impulses "$impulses" \
        --maximum-lag-ms "$maximum_lag_ms" \
        --output "$probe" >/dev/null 2>"$work_dir/err.txt"

    if [[ ! -s "$probe" ]]; then
        print -r -- "[$(date -u +%H:%M:%SZ)] burst $iteration: harness error"
        [[ -s "$work_dir/err.txt" ]] && sed 's/^/    /' "$work_dir/err.txt"
        sleep 2
        continue
    fi

    USB16X16_PROBE="$probe" \
    USB16X16_PEAK_THRESHOLD="$peak_threshold" \
    USB16X16_SPREAD_LIMIT="$spread_limit" \
    USB16X16_ITERATION="$iteration" \
    /usr/bin/python3 <<'PYEOF'
import json
import math
import os

probe = json.load(open(os.environ["USB16X16_PROBE"]))
peak = float(probe["capturedPeak"])
correlation = probe["correlation"]
delays = correlation["perImpulseDelaySamples"]
statistics = correlation["statistics"]
spread = max(delays) - min(delays)
threshold = float(os.environ["USB16X16_PEAK_THRESHOLD"])
spread_limit = int(os.environ["USB16X16_SPREAD_LIMIT"])
locked = peak >= threshold and spread <= spread_limit

dbfs = 20.0 * math.log10(peak) if peak > 0 else float("-inf")
stamp = os.popen("date -u +%H:%M:%SZ").read().strip()
verdict = "LOCKED" if locked else "silence"
detail = ""
if locked:
    detail = "  delay=%d samples %.3f ms" % (
        statistics["medianSamples"],
        statistics["medianMilliseconds"],
    )
print(
    "[%s] burst %-3s peak=%.6f (%6.1f dBFS)  spread=%-4d %s%s"
    % (
        stamp,
        os.environ["USB16X16_ITERATION"],
        peak,
        dbfs,
        spread,
        verdict,
        detail,
    )
)
open(os.environ["USB16X16_PROBE"] + ".locked", "w").write("1" if locked else "0")
PYEOF

    if [[ "$(cat "$probe.locked" 2>/dev/null)" == 1 ]]; then
        (( consecutive_locks += 1 ))
        if (( locked_once == 0 && consecutive_locks >= required_consecutive )); then
            locked_once=1
            print -r -- ""
            print -r -- "=================================================="
            print -r -- " RETURN SIGNAL DETECTED - routing is landing."
            print -r -- "=================================================="
            print -r -- ""
        fi
    else
        consecutive_locks=0
    fi
    sleep 1
done

print -r -- ""
if (( locked_once )); then
    print -r -- "watch window ended; a return signal was seen."
else
    print -r -- "watch window ended; no return signal was ever detected."
fi
