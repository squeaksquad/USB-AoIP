#!/bin/zsh
# run-sweep.sh [DROPS] [OPENS]: the 96 kHz prime-drop sweep (2026-10-31). The installed owner c84e6a36 as a
# candidate at arm A with --prime-drop D --capture-drain, OPENS harness opens of 100 impulses each per D.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-primedrop-20261031
DROPS=(${=1:-48 72 96}); OPENS=${2:-6}
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
B=/home/bdimaio/usb-16x16-work/dante-mode
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
ssh $P $PI 'sudo -n systemctl stop usb16x16-dante'; log "service stopped"
for drop in $DROPS; do
  ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-candidate stop >/dev/null 2>&1; sudo -n /usr/local/sbin/usb16x16-dante-candidate start $B/owner/usb16x16-dante-owner-ratepoll CONFIG=$B/config/asound-inferno-owner-rate96-usb-aoip.conf --seconds 0 --rate 96000 --period 64 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192 --prime-drop $drop --capture-drain > /dev/shm/cand-start.txt 2>&1 < /dev/null"
  log "D=$drop: candidate started; $(ssh $P $PI 'sleep 5; l=$(ls -t /dev/shm/dante-owner-*.log | head -1); grep -m1 "^START" $l | grep -o "prime_drop=.*"; grep -m1 USBOPEN $l | grep -o "host_rate=[a-z]*"')"
  sleep 60
  work/dante-mode/measure-candidate.sh noise 32 sw96d$drop > $D/sw96d$drop-noise.out 2>&1
  log "D=$drop noise: $(grep -o 'zero runs>=4: [0-9]*' $D/sw96d$drop-noise.out | tail -1)"
  for k in $(seq 1 $OPENS); do
    work/dante-mode/measure-candidate.sh 32 100 sw96d$drop-$k > $D/sw96d$drop-$k.out 2>&1
    link=$(ssh $P $PI 'l=$(ls -t /dev/shm/dante-owner-*.log | head -1); grep "USBLINK .*tx=flow" $l | tail -1 | grep -o "tx_prime_found=[0-9]* tx_prime_dropped=[0-9]* tx_unanchored=[0-9]* tx_drained=[0-9]*"')
    log "D=$drop open $k: $(grep daw_timeline $D/sw96d$drop-$k.out | tail -1 | grep -o '([0-9]*) = [0-9]*') | $link"
  done
  ssh $P $PI "l=\$(ls -t /dev/shm/dante-owner-*.log | head -1); cp \$l /dev/shm/sw96d$drop-owner.log; grep '^USB t=' \$l | tail -1" | sed "s/^/D=$drop owner: /" | tee -a $D/steps.txt
  scp -q $P $PI:/dev/shm/sw96d$drop-owner.log $D/
done
ssh $P $PI 'sudo -n /usr/local/sbin/usb16x16-dante-candidate stop' >/dev/null 2>&1; log "candidate stopped; service left stopped"
