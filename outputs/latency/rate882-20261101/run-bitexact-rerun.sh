#!/bin/zsh
# run-bitexact-rerun.sh: the battery's bitexact failed on one all-channel 8-frame swap at 267 s with the owner
# clean. Repeat it twice (360 s each) on the same candidate (D=72) to see whether it recurs; no capture.
# Domain to 88.2 with the Pi out (as run-sweep.sh), then back to 48 and the service (as run-battery-d72.sh).
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate882-20261101
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
B=/home/bdimaio/usb-16x16-work/dante-mode
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
ownerlog='l=$(ls -t /dev/shm/dante-owner-*.log | head -1)'
osascript -e 'quit app "DanteSwitcher"' >/dev/null 2>&1; sleep 2; log "rerun: Dante Switcher running: $(pgrep -x DanteSwitcher || echo no)"
st=$(ssh $P $PI 'systemctl is-active usb16x16-dante-rate; grep -o "^RATE=[0-9]*" /etc/usb16x16/dante/owner.conf; cat /run/usb16x16-dante-startcheck/status' | tr '\n' ' ')
log "before: $st"
case "$st" in inactive*state=ok*) ;; *) log "the service is not settled at 48; stopping here"; exit 1 ;; esac
ssh $P $PI 'sudo -n systemctl stop usb16x16-dante'; log "service stopped"
log "dante-sync sync --rate 88200 --allow-band-up"; "$S" sync --rate 88200 --allow-band-up 2>&1 | tee -a $D/steps.txt
sleep 5; log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | tee -a $D/steps.txt
log "$("$S" status 2>&1 | grep -E 'Leader|MHLink')"
ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-candidate stop >/dev/null 2>&1; sudo -n /usr/local/sbin/usb16x16-dante-candidate start $B/owner/usb16x16-dante-owner-ratepoll CONFIG=$B/config/asound-inferno-owner-rate882-usb-aoip.conf --seconds 0 --rate 88200 --period 64 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192 --prime-drop 72 --capture-drain > /dev/shm/cand-start.txt 2>&1 < /dev/null"
log "candidate started; $(ssh $P $PI "sleep 5; $ownerlog; grep -m1 USBOPEN \$l | grep -o 'host_rate=[a-z]*'")"
sleep 60
for k in 1 2; do
  T=$(date -u +%Y%m%dT%H%M%SZ); out=outputs/latency/d72r882-bitexact-360s-32f-$T.json
  "$H" bitexact --device "${USB16X16_DEVICE:-USB-AoIP}" --buffer-frames 32 --seconds 360 --loop-channels 8 --output $out > $D/d72r882-bitexact$k.out 2> ${out%.json}.err
  log "bitexact $k exit $?: $out $(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('pass', d['pass'], [(c['source'], c['lostLocks'], c['slips']) for c in d['channels'] if c['lostLocks'] or c['slips']][:3])" $out)"
done
log "owner: $(ssh $P $PI "$ownerlog; grep '^USB t=' \$l | tail -1" | grep -o 'tx_reprimes=[0-9]*\|capture_faults=[0-9]*\|playback_faults=[0-9]*\|servo_rejected=[0-9]*\|out_holes=[^ ]*\|back_holes=[^ ]*' | tr '\n' ' ')"
log "owner net: $(ssh $P $PI "$ownerlog; grep '^OWNER t=' \$l | tail -1" | grep -o 'resyncs=[0-9]*\|lost=[0-9]*\|net_errors=[0-9]*' | tr '\n' ' ')"
ssh $P $PI "$ownerlog; cp \$l /dev/shm/d72r882-owner.log"; scp -q $P $PI:/dev/shm/d72r882-owner.log $D/
ssh $P $PI 'sudo -n /usr/local/sbin/usb16x16-dante-candidate stop' >/dev/null 2>&1; log "candidate stopped"
log "dante-sync sync --rate 48000"; "$S" sync --rate 48000 2>&1 | tee -a $D/steps.txt
sleep 5; log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | tee -a $D/steps.txt
ssh $P $PI 'sudo -n systemctl start usb16x16-dante'; log "service started"
for t in $(seq 60); do sleep 5; s=$(ssh $P $PI 'cat /run/usb16x16-dante-startcheck/status 2>/dev/null'); [[ $s == state=ok* && $(ssh $P $PI 'systemctl is-active usb16x16-dante') == active ]] && break; done
log "start check: $s"
log "$("$S" status 2>&1 | grep -E 'Leader|USB-AoIP')"
open -a DanteSwitcher; sleep 3; log "Dante Switcher relaunched: $(pgrep -x DanteSwitcher)"
log "rerun done"
