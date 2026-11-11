#!/bin/zsh
# Measure the round trip against a DSP candidate, both arms.
#
# The shim measure-phase4-roundtrip.sh is to run-phase4-candidate-safe.sh what
# this is to run-dsp-candidate-safe.sh: it sets the remote script, its ready
# file and its arguments, then hands off to the common measurement wrapper.
#
# The candidate wrapper hardcodes the accepted profile, so the only argument
# that varies between the two arms is the preset. "none" is the direct control:
# the same binary with no --dsp-preset, the stage absent rather than bypassed.
#
# Usage: measure-dsp-roundtrip.sh SECONDS FRAMES IMPULSES PRESET|none [LAG_MS] [LIVE_TOGGLE_PRESET [PERIOD_S]]
#
# LIVE_TOGGLE_PRESET (2026-09-13) is handed to the Pi wrapper as its third
# argument: the candidate's live file is enabled and that preset is pushed
# over PRESET every PERIOD_S seconds (default 2) for the whole run.
set -uo pipefail

script_dir=${0:A:h}
seconds=${1:-480}
coreaudio_frames=${2:-64}
impulses=${3:-800}
dsp_preset=${4:-/home/bdimaio/usb-16x16-work/dsp-verify/loaded.dsp}
maximum_lag_ms=${5:-200}
live_toggle=${6:-}
live_period=${7:-2}

export USB16X16_REMOTE_CANDIDATE=/usr/local/sbin/run-dsp-candidate-safe.sh
export USB16X16_REMOTE_READY_FILE=/tmp/usb16x16-phase4-candidate.ready
export USB16X16_REMOTE_ARGUMENTS="$seconds $dsp_preset${live_toggle:+ $live_toggle $live_period}"
export USB16X16_PATH_LABEL="Phase 4 Ferrofish return path, DSP candidate"
export USB16X16_REQUIRED_SIGNAL_PROBES=3
# As the Phase 4 shim: buffer-192 points show an 8-9 sample impulse bimodality.
export USB16X16_READY_MAX_SPREAD_SAMPLES=${USB16X16_READY_MAX_SPREAD_SAMPLES:-9}

exec "$script_dir/measure-aes67-roundtrip.sh" \
    "$seconds" "$coreaudio_frames" "$impulses" "$maximum_lag_ms"
