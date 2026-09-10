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
# Usage: measure-dsp-roundtrip.sh SECONDS FRAMES IMPULSES PRESET|none [LAG_MS]
set -uo pipefail

script_dir=${0:A:h}
seconds=${1:-480}
coreaudio_frames=${2:-64}
impulses=${3:-800}
dsp_preset=${4:-/home/bdimaio/usb-16x16-work/dsp-verify/loaded.dsp}
maximum_lag_ms=${5:-200}

export USB16X16_REMOTE_CANDIDATE=/usr/local/sbin/run-dsp-candidate-safe.sh
export USB16X16_REMOTE_READY_FILE=/tmp/usb16x16-phase4-candidate.ready
export USB16X16_REMOTE_ARGUMENTS="$seconds $dsp_preset"
export USB16X16_PATH_LABEL="Phase 4 Ferrofish return path, DSP candidate"
export USB16X16_REQUIRED_SIGNAL_PROBES=3
# As the Phase 4 shim: buffer-192 points show an 8-9 sample impulse bimodality.
export USB16X16_READY_MAX_SPREAD_SAMPLES=${USB16X16_READY_MAX_SPREAD_SAMPLES:-9}

exec "$script_dir/measure-aes67-roundtrip.sh" \
    "$seconds" "$coreaudio_frames" "$impulses" "$maximum_lag_ms"
