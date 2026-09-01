#!/bin/zsh
# Sample the multicast arriving at the Mac's AoIP interface once per interval.
#
# The Mac joins no audio group - only SAP - so anything beyond a trickle here is
# the switch flooding rather than forwarding. Run alongside a candidate to see
# whether IGMP snooping actually filters in steady state, or whether its entries
# age out into flooding at the group membership interval.
#
# usage: multicast-rate-watch.sh [interface] [seconds] [interval]
set -euo pipefail
zmodload zsh/datetime
interface=${1:-en12}
duration=${2:-420}
interval=${3:-5}

read_bytes() { netstat -ib | awk -v i="$interface" '$1==i && $3 ~ /Link/ {print $7; exit}' }

started=$EPOCHSECONDS
previous=$(read_bytes)
print -r -- "# multicast-rate-watch on $interface, ${duration}s at ${interval}s intervals"
print -r -- "# start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
print -r -- "# offset   Mbps"
while (( EPOCHSECONDS - started < duration )); do
    sleep "$interval"
    current=$(read_bytes)
    offset=$(( EPOCHSECONDS - started ))
    printf '+%7d %8.1f\n' "$offset" "$(( (current - previous) * 8.0 / interval / 1000000 ))"
    previous=$current
done
