#!/bin/bash
# Step 7 of LIVE_INSTALL_PLAN.md: alternate two same-shape artifacts into the
# service's live file every PERIOD seconds for SECONDS, by rename, as root
# (the applier is the writer in production; this is the soak's pusher).
# Both hashes are pinned; the bridge answers each on dsp-live.status.
#   sudo ./live-toggle-push.sh SECONDS [PERIOD]
set -euo pipefail
export TZ=UTC   # the push log stamps are labelled Z; make them so
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run as root with sudo" >&2; exit 2; }
seconds=${1:-600}; period=${2:-2}
live=/run/usb16x16/dsp-live.dsp
[ "$(sha256sum user-base.dsp | cut -c1-64)" = "79fbc5f9a42b0e7f119fa3ba041b634fb5ee144299c04dc1a3ec0058a7d0f0dc" ] || { echo "user-base.dsp hash mismatch" >&2; exit 11; }
[ "$(sha256sum user-toggle.dsp | cut -c1-64)" = "d54a7229ebd0c27b8ef16756b16e87910523bd1ff47e50f5fe75b6057c365fba" ] || { echo "user-toggle.dsp hash mismatch" >&2; exit 11; }
[ "$(sha256sum /etc/usb16x16/dsp/user-immersive-stereo-subs.dsp | cut -c1-64)" = "79fbc5f9a42b0e7f119fa3ba041b634fb5ee144299c04dc1a3ec0058a7d0f0dc" ] || { echo "the installed user preset is not user-base.dsp; refusing" >&2; exit 12; }
base_text=$(cat user-base.dsp; printf x); base_text=${base_text%x}
toggle_text=$(cat user-toggle.dsp; printf x); toggle_text=${toggle_text%x}
log=/run/usb16x16-live-pushes.log
: > "$log"
end=$((SECONDS + seconds)); pushes=0
while [ $SECONDS -lt $end ]; do
  if [ $((pushes % 2)) -eq 0 ]; then text=$toggle_text; name=toggle; else text=$base_text; name=base; fi
  printf '%s' "$text" > "$live.tmp" && chmod 644 "$live.tmp" && mv "$live.tmp" "$live"
  pushes=$((pushes + 1))
  printf '%(%Y-%m-%dT%H:%M:%SZ)T push=%s file=%s\n' -1 "$pushes" "$name" >> "$log"
  sleep "$period"
done
# Leave the installed preset's numbers running.
printf '%s' "$base_text" > "$live.tmp" && chmod 644 "$live.tmp" && mv "$live.tmp" "$live"
echo "pushes=$pushes log=$log status=$(cat /run/usb16x16/dsp-live.status)"
