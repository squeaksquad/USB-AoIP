#!/bin/zsh
# run-battery-d96.sh: the 96 kHz battery on candidate c84e6a36 arm A with --prime-drop 96 --capture-drain.
# Domain to 96, service stopped, candidate; noise probe, four loaded 800-impulse runs, 600 s 8-channel soak,
# bitexact --loop-channels 8 360 s; the return queue's floor over the run; service and domain back at 48.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-primedrop96-20261101
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
B=/home/bdimaio/usb-16x16-work/dante-mode
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
ownerlog='l=$(ls -t /dev/shm/dante-owner-*.log | head -1)'
counters(){ ssh $P $PI "$ownerlog; grep '^USB t=' \$l | tail -1"; }
log "dante-sync sync --rate 96000 --allow-band-up"; "$S" sync --rate 96000 --allow-band-up 2>&1 | tee -a $D/steps.txt
sleep 5
log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | tee -a $D/steps.txt
ssh $P $PI 'sudo -n systemctl stop usb16x16-dante'; log "service stopped"
ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-candidate stop >/dev/null 2>&1; sudo -n /usr/local/sbin/usb16x16-dante-candidate start $B/owner/usb16x16-dante-owner-ratepoll CONFIG=$B/config/asound-inferno-owner-rate96-usb-aoip.conf --seconds 0 --rate 96000 --period 64 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192 --prime-drop 96 --capture-drain > /dev/shm/cand-start.txt 2>&1 < /dev/null"
log "candidate started; $(ssh $P $PI "sleep 5; $ownerlog; grep -m1 '^START' \$l | grep -o 'prime_drop=.*'; grep -m1 USBOPEN \$l | grep -o 'host_rate=[a-z]*'")"
sleep 240   # the settle after a rate move (first opens can read high)
work/dante-mode/measure-candidate.sh noise 32 d96b96 > $D/d96b96-noise.out 2>&1
log "noise: $(grep -o 'zero runs>=4: [0-9]*' $D/d96b96-noise.out | tail -1)"
for i in 1 2 3 4; do
  USB16X16_OTHER_LOAD=0.1 work/dante-mode/measure-candidate.sh 32 800 d96b96loaded$i > $D/d96b96loaded$i.out 2>&1
  link=$(ssh $P $PI "$ownerlog; grep 'USBLINK .*tx=flow' \$l | tail -1 | grep -o 'tx_prime_found=[0-9]* tx_prime_dropped=[0-9]* tx_unanchored=[0-9]*'")
  log "loaded$i: $(grep daw_timeline $D/d96b96loaded$i.out | tail -1) | $link"
done
USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak 600 32 d96b96 > $D/d96b96-soak.out 2>&1
log "soak 600: $(grep -E '^soak:' $D/d96b96-soak.out | tail -1) / $(grep -E '^rate=' $D/d96b96-soak.out | tail -1)"
T=$(date -u +%Y%m%dT%H%M%SZ); out=outputs/latency/d96b96-bitexact-360s-32f-$T.json
"$H" bitexact --device "${USB16X16_DEVICE:-USB-AoIP}" --buffer-frames 32 --seconds 360 --loop-channels 8 --output $out > $D/d96b96-bitexact.out 2> ${out%.json}.err
log "bitexact exit $?: $out"; tail -5 ${out%.json}.err | tee -a $D/steps.txt
log "owner counters after:"; counters | tee -a $D/steps.txt
ssh $P $PI "$ownerlog; cp \$l /dev/shm/d96b96-owner.log"; scp -q $P $PI:/dev/shm/d96b96-owner.log $D/
log "rx_depth minimum over the flowing lines: $(grep '^USB t=.*tx=flow rx=flow' $D/d96b96-owner.log | grep -o 'rx_depth=[0-9]*' | cut -d= -f2 | sort -n | head -1)"
ssh $P $PI 'sudo -n /usr/local/sbin/usb16x16-dante-candidate stop >/dev/null 2>&1; sudo -n systemctl start usb16x16-dante'; log "candidate stopped, service started at 96 (D=48 installed)"
sleep 20
log "dante-sync sync --rate 48000"; "$S" sync --rate 48000 2>&1 | tee -a $D/steps.txt
sleep 5
log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | tee -a $D/steps.txt
sleep 30
log "start check: $(ssh $P $PI 'cat /run/usb16x16-dante-startcheck/status')"
log "battery done"
