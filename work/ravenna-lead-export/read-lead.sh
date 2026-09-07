#!/bin/bash
# Print each sink's sink_min_time from the daemon API on the Pi (read-only).
# Every GET closes one interval and starts the next, so read once before a run
# and once after it: the second read is the minimum over the run. Optional
# label is echoed with the line. Needs the lead-export module (0002); on the
# older modules the field is always 0.
set -euo pipefail
label=${1:-}
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ssh bdimaio@192.168.1.201 'for id in 0 1; do printf "sink %s " "$id"; curl -s "http://127.0.0.1:8080/api/sink/status/$id" | tr -d " \n"; echo; done' |
  while IFS= read -r line; do
    min=${line##*\"sink_min_time\":}; min=${min%\}}
    printf '%s %s %s sink_min_time_us=%s\n' "$stamp" "${label:--}" "${line%% \{*}" "$min"
  done
