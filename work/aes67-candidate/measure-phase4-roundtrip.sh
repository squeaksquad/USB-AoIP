#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
seconds=${1:-480}
coreaudio_frames=${2:-64}
impulses=${3:-40}
maximum_lag_ms=${4:-200}
period_frames=${USB16X16_PHASE4_PERIOD_FRAMES:-96}
buffer_frames=${USB16X16_PHASE4_BUFFER_FRAMES:-384}
ring_frames=${USB16X16_PHASE4_RING_FRAMES:-768}
target_frames=${USB16X16_PHASE4_TARGET_FRAMES:-192}

export USB16X16_REMOTE_CANDIDATE=/usr/local/sbin/run-phase4-candidate-safe.sh
export USB16X16_REMOTE_READY_FILE=/tmp/usb16x16-phase4-candidate.ready
export USB16X16_REMOTE_ARGUMENTS="$seconds $period_frames $buffer_frames $ring_frames $target_frames"
export USB16X16_PATH_LABEL="Phase 4 Ferrofish return path"
export USB16X16_REQUIRED_SIGNAL_PROBES=3

exec "$script_dir/measure-aes67-roundtrip.sh" \
    "$seconds" "$coreaudio_frames" "$impulses" "$maximum_lag_ms"
