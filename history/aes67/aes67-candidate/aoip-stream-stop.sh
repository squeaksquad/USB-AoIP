#!/bin/bash
# The stream-stop test for the AoIP loop, timed by the wrapper's own ready
# file rather than by hand (the first attempt's deletes landed after the run
# had ended). Run on the Pi in a second shell right after starting
# run-aoip-candidate-safe.sh; no root: the daemon API is local.
#
#   waits for /tmp/usb16x16-phase4-candidate.ready (the loop bridge is up)
#   + HOLD_S     deletes both sinks: no RTP reaches the RAVENNA capture
#   + GAP_S      re-adds both at delay 103, the way the wrapper adds them
#                (each PUT returns after about 30 s)
#
# Prints a UTC stamp at each step so the events can be placed on the bridge's
# own timeline (the bridge log's ZERORUN lines carry utc=).
#
# Usage: aoip-stream-stop.sh [HOLD_S=60] [GAP_S=30]
set -uo pipefail
hold_s=${1:-60}
gap_s=${2:-30}
ready_file=/tmp/usb16x16-phase4-candidate.ready
status_json=/home/bdimaio/usb-16x16-work/aes67-daemon-src/runtime/status.json
api=http://127.0.0.1:8080
stamp() { printf '%s %s\n' "$(date -u +%H:%M:%S.%3NZ)" "$*"; }

stamp "waiting for $ready_file"
waited=0
while [ ! -e "$ready_file" ]; do
  sleep 1
  waited=$((waited + 1))
  if [ "$waited" -gt 300 ]; then
    stamp "no ready file after ${waited}s; is the candidate running?"
    exit 1
  fi
done
stamp "loop bridge up ($(cat "$ready_file")); holding ${hold_s}s"
sleep "$hold_s"
[ -e "$ready_file" ] || { stamp "the candidate ended before the deletes; nothing done"; exit 1; }
stamp "deleting sink 0 and sink 1"
curl -s -m 30 -X DELETE "$api/api/sink/0" -o /dev/null -w 'sink 0 delete: %{http_code}\n'
curl -s -m 30 -X DELETE "$api/api/sink/1" -o /dev/null -w 'sink 1 delete: %{http_code}\n'
stamp "both sinks deleted; holding ${gap_s}s with no stream arriving"
sleep "$gap_s"
[ -e "$ready_file" ] || { stamp "the candidate ended during the gap; sinks left deleted (the wrapper tears the daemon down)"; exit 1; }
for id in 0 1; do
  stamp "re-adding sink $id at delay 103 (the PUT takes about 30 s)"
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
keys=("name","io","delay","use_sdp","source","sdp","ignore_refclk_gmid","map")
s={k:d["sinks"][int(sys.argv[2])][k] for k in keys}
s["delay"]=103
print(json.dumps(s))' "$status_json" "$id" |
    curl -s -m 120 -X PUT "$api/api/sink/$id" -H 'Content-Type: application/json' --data-binary @- \
      -o /dev/null -w "sink $id put: %{http_code}\n"
  stamp "sink $id put returned"
done
curl -s -m 10 "$api/api/sinks" | grep -o '"delay"[^,]*' | tr '\n' ' '; echo
stamp "done; let the candidate run to DONE"
