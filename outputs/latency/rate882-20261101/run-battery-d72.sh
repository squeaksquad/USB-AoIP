#!/bin/zsh
# run-battery-d72.sh: the 88.2 kHz battery (RATE882_PLAN.md phase 3b) on candidate c84e6a36 at 96's arm A
# with --prime-drop 72 --capture-drain, the domain already at 88.2 and the service stopped (run-sweep.sh).
# Noise probe, four loaded 800-impulse runs, 600 s 8-channel soak, bitexact --loop-channels 8 360 s; the
# return queue's floor; then the domain to 48 with the Pi out, the service started, settled at 48.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate882-20261101
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
B=/home/bdimaio/usb-16x16-work/dante-mode
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
ownerlog='l=$(ls -t /dev/shm/dante-owner-*.log | head -1)'
counters(){ ssh $P $PI "$ownerlog; grep '^USB t=' \$l | tail -1"; }
log "battery D=72: $("$S" status 2>&1 | grep -E 'Leader|MHLink')"
ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-candidate stop >/dev/null 2>&1; sudo -n /usr/local/sbin/usb16x16-dante-candidate start $B/owner/usb16x16-dante-owner-ratepoll CONFIG=$B/config/asound-inferno-owner-rate882-usb-aoip.conf --seconds 0 --rate 88200 --period 64 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192 --prime-drop 72 --capture-drain > /dev/shm/cand-start.txt 2>&1 < /dev/null"
log "candidate started; $(ssh $P $PI "sleep 5; $ownerlog; grep -m1 '^START' \$l | grep -o 'prime_drop=.*'; grep -m1 USBOPEN \$l | grep -o 'host_rate=[a-z]*'")"
sleep 60
work/dante-mode/measure-candidate.sh noise 32 d72b882 > $D/d72b882-noise.out 2>&1
log "noise: $(grep -o 'zero runs>=4: [0-9]*' $D/d72b882-noise.out | tail -1)"
for i in 1 2 3 4; do
  USB16X16_OTHER_LOAD=0.1 work/dante-mode/measure-candidate.sh 32 800 d72b882loaded$i > $D/d72b882loaded$i.out 2>&1
  link=$(ssh $P $PI "$ownerlog; grep 'USBLINK .*tx=flow' \$l | tail -1 | grep -o 'tx_prime_found=[0-9]* tx_prime_dropped=[0-9]* tx_unanchored=[0-9]*'")
  log "loaded$i: $(grep daw_timeline $D/d72b882loaded$i.out | tail -1) | $link"
done
USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak 600 32 d72b882 > $D/d72b882-soak.out 2>&1
log "soak 600: $(grep -E '^soak:' $D/d72b882-soak.out | tail -1) / $(grep -E '^rate=' $D/d72b882-soak.out | tail -1)"
T=$(date -u +%Y%m%dT%H%M%SZ); out=outputs/latency/d72b882-bitexact-360s-32f-$T.json
"$H" bitexact --device "${USB16X16_DEVICE:-USB-AoIP}" --buffer-frames 32 --seconds 360 --loop-channels 8 --output $out > $D/d72b882-bitexact.out 2> ${out%.json}.err
log "bitexact exit $?: $out"; tail -5 ${out%.json}.err | tee -a $D/steps.txt
log "owner counters after:"; counters | tee -a $D/steps.txt
ssh $P $PI "$ownerlog; cp \$l /dev/shm/d72b882-owner.log"; scp -q $P $PI:/dev/shm/d72b882-owner.log $D/
log "rx_depth minimum over the flowing lines: $(grep '^USB t=.*tx=flow rx=flow' $D/d72b882-owner.log | grep -o 'rx_depth=[0-9]*' | cut -d= -f2 | sort -n | head -1)"
ssh $P $PI 'sudo -n /usr/local/sbin/usb16x16-dante-candidate stop' >/dev/null 2>&1; log "candidate stopped"
log "dante-sync sync --rate 48000"; "$S" sync --rate 48000 2>&1 | tee -a $D/steps.txt
sleep 5
log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | tee -a $D/steps.txt
ssh $P $PI 'sudo -n systemctl start usb16x16-dante'; log "service started"
for t in $(seq 60); do sleep 5; s=$(ssh $P $PI 'cat /run/usb16x16-dante-startcheck/status 2>/dev/null'); [[ $s == state=ok* && $(ssh $P $PI 'systemctl is-active usb16x16-dante') == active ]] && break; done
log "start check: $s"
work/dante-mode/measure-candidate.sh noise 32 b882back48 > $D/back48-noise.out 2>&1; log "48 noise: $(grep -o 'zero runs>=4: [0-9]*' $D/back48-noise.out | tail -1)"
work/dante-mode/measure-candidate.sh 32 100 b882back48 > $D/back48.out 2>&1; log "48 open: $(grep daw_timeline $D/back48.out | tail -1)"
"$S" status 2>&1 | tee -a $D/steps.txt
open -a DanteSwitcher; sleep 3; log "Dante Switcher relaunched: $(pgrep -x DanteSwitcher)"
log "battery done"
