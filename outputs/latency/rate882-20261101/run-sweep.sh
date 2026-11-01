#!/bin/zsh
# run-sweep.sh [DROPS] [OPENS]: 88.2 kHz phases 1 and 3a (RATE882_PLAN.md, 2026-11-01). With the service
# stopped at 48 (the Pi out of the move: the installed config does not offer 88.2), the domain and the Mac's
# USB-AoIP to 88.2 by dante-sync (it holds the 10 s 88.2 settle); status. Then the installed owner c84e6a36 as
# a candidate on asound-inferno-owner-rate882-usb-aoip.conf at 96's arm A, --prime-drop D --capture-drain,
# a noise probe and OPENS opens of 100 impulses per D. Leaves the candidate stopped and the domain at 88.2.
# The Metric Halo follows by the second sync (--source usb-aoip); SKIP_MOVE=1 starts at the sweep with the
# service stopped and the domain already at 88.2. Dante Switcher's app is quit for the run (its follow would act on the moves).
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate882-20261101
DROPS=(${=1:-48 72 96}); OPENS=${2:-6}
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
B=/home/bdimaio/usb-16x16-work/dante-mode
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
osascript -e 'quit app "DanteSwitcher"' >/dev/null 2>&1; sleep 2; log "Dante Switcher running: $(pgrep -x DanteSwitcher || echo no)"
if [ -z "${SKIP_MOVE:-}" ]; then
st=$(ssh $P $PI 'systemctl is-active usb16x16-dante-rate; grep -o "^RATE=[0-9]*" /etc/usb16x16/dante/owner.conf; cat /run/usb16x16-dante-startcheck/status' | tr '\n' ' ')
log "before: $st"
case "$st" in inactive*state=ok*) ;; *) log "the service is not settled at 48; stopping here"; exit 1 ;; esac
scp -q $P work/dante-mode/config/asound-inferno-owner-rate882-usb-aoip.conf work/dante-mode/config/asound-inferno-owner-usb-aoip-rate882.conf $PI:$B/config/
ssh $P $PI 'sudo -n systemctl stop usb16x16-dante'; log "service stopped"
log "dante-sync sync --rate 88200 --allow-band-up"; "$S" sync --rate 88200 --allow-band-up 2>&1 | tee -a $D/steps.txt
sleep 5
log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | tee -a $D/steps.txt
fi
log "dante-sync status"; "$S" status 2>&1 | tee -a $D/steps.txt
for drop in $DROPS; do
  ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-candidate stop >/dev/null 2>&1; sudo -n /usr/local/sbin/usb16x16-dante-candidate start $B/owner/usb16x16-dante-owner-ratepoll CONFIG=$B/config/asound-inferno-owner-rate882-usb-aoip.conf --seconds 0 --rate 88200 --period 64 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192 --prime-drop $drop --capture-drain > /dev/shm/cand-start.txt 2>&1 < /dev/null"
  log "D=$drop: candidate started; $(ssh $P $PI 'sleep 5; cat /dev/shm/cand-start.txt | tail -2; l=$(ls -t /dev/shm/dante-owner-*.log | head -1); grep -m1 "^START" $l | grep -o "prime_drop=.*"; grep -m1 USBOPEN $l | grep -o "host_rate=[a-z]*"')"
  sleep 60
  work/dante-mode/measure-candidate.sh noise 32 sw882d$drop > $D/sw882d$drop-noise.out 2>&1
  log "D=$drop noise: $(grep -o 'zero runs>=4: [0-9]*' $D/sw882d$drop-noise.out | tail -1)"
  for k in $(seq 1 $OPENS); do
    work/dante-mode/measure-candidate.sh 32 100 sw882d$drop-$k > $D/sw882d$drop-$k.out 2>&1
    link=$(ssh $P $PI 'l=$(ls -t /dev/shm/dante-owner-*.log | head -1); grep "USBLINK .*tx=flow" $l | tail -1 | grep -o "tx_prime_found=[0-9]* tx_prime_dropped=[0-9]* tx_unanchored=[0-9]* tx_drained=[0-9]*"')
    log "D=$drop open $k: $(grep daw_timeline $D/sw882d$drop-$k.out | tail -1) | $link"
  done
  ssh $P $PI "l=\$(ls -t /dev/shm/dante-owner-*.log | head -1); cp \$l /dev/shm/sw882d$drop-owner.log; grep '^USB t=' \$l | tail -1" | sed "s/^/D=$drop owner: /" | tee -a $D/steps.txt
  scp -q $P $PI:/dev/shm/sw882d$drop-owner.log $D/
  log "D=$drop rx_depth min: $(grep '^USB t=.*tx=flow rx=flow' $D/sw882d$drop-owner.log | grep -o 'rx_depth=[0-9]*' | cut -d= -f2 | sort -n | head -1)"
done
ssh $P $PI 'sudo -n /usr/local/sbin/usb16x16-dante-candidate stop' >/dev/null 2>&1; log "candidate stopped; service left stopped, domain at 88.2"
log "sweep done"
