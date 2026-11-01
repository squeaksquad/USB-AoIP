#!/bin/zsh
# run-persist.sh: is the tight case the macOS silent state? A tight switch from 48, then two plain probes
# at 88.2 with no rate change (the silent state persists until the next change), then the recovery.
cd /Users/bryandimaio/Development/USB-AoIP
source <(sed -n '/^D=/,/^tight882/p' outputs/latency/rate882-macrule-20261101/run-tight.sh)
log "persist: start; service: $(pi 'systemctl is-active usb16x16-dante-rate.service; cat /run/usb16x16-dante-startcheck/status')"
pi "sudo -n systemctl stop usb16x16-dante; mkdir -p /dev/shm/rate882m"; log "service stopped"
settle_to 48000 p-r48; tight882 p-r882tight
probe p-r882plain1; loop 88200 p-loop2; probe p-r882plain2
pi "pkill -x alsaloop"; sleep 1; log "$($D/setrate USB-AoIP 48000)"; sleep 10
pi "sudo -n systemctl start usb16x16-dante"
for t in $(seq 60); do sleep 5; s=$(pi 'cat /run/usb16x16-dante-startcheck/status 2>/dev/null'); [[ $s == state=ok* && $(pi 'systemctl is-active usb16x16-dante') == active ]] && break; done
log "service started: $s"
open -a DanteSwitcher; sleep 3; log "Dante Switcher relaunched: $(pgrep -x DanteSwitcher)"
log "persist done"
