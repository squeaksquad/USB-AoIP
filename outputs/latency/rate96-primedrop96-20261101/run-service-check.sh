#!/bin/zsh
# run-service-check.sh: after install-dante-rate96-drop96.sh, the service at 96: noise probe, three opens of
# 100 impulses, 120 s soak on 1-8; then back to 48 (noise probe, 100 impulses).
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-primedrop96-20261101
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
log(){ echo "$(date -u +%T) $*" | tee -a $D/service-steps.txt; }
eval "$(grep '^settled()' $D/run-battery-d96.sh)"
out=$(settled 48000); log "before: $out"
log "dante-sync sync --rate 96000 --allow-band-up"; "$S" sync --rate 96000 --allow-band-up 2>&1 | grep -E '^  |k:' | tee -a $D/service-steps.txt
sleep 5; "$S" sync --source usb-aoip 2>&1 | grep -E 'k:' | tee -a $D/service-steps.txt
out=$(settled 96000); rc=$?; log "$out"; [ $rc = 0 ] || exit 1
log "$(ssh $P $PI "journalctl -u usb16x16-dante --since '-5min' --no-pager | grep START | tail -1 | grep -o 'rate=96000.*prime_drop=[0-9]* capture_drain=[01]' | grep -o 'rate=96000\|prime_drop=[0-9]*\|capture_drain=[01]' | tr '\n' ' '")"
sleep 180   # the settle after a rate move
work/dante-mode/measure-candidate.sh noise 32 svcd96 > $D/svcd96-noise.out 2>&1
log "noise: $(grep -o 'zero runs>=4: [0-9]*' $D/svcd96-noise.out | tail -1)"
for k in 1 2 3; do
  work/dante-mode/measure-candidate.sh 32 100 svcd96-$k > $D/svcd96-$k.out 2>&1
  link=$(ssh $P $PI "journalctl -u usb16x16-dante --since '-2min' --no-pager | grep 'USBLINK .*tx=flow' | tail -1 | grep -o 'tx_prime_dropped=[0-9]* tx_unanchored=[0-9]*'")
  log "service open $k: $(grep daw_timeline $D/svcd96-$k.out | tail -1) | $link"
done
USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak 120 32 svcd96 > $D/svcd96-soak.out 2>&1
log "soak 120: $(grep -E '^soak:' $D/svcd96-soak.out | tail -1)"
log "owner: $(ssh $P $PI "journalctl -u usb16x16-dante --since '-3min' --no-pager | grep 'USB t=' | tail -1 | grep -o 'tx_reprimes=[0-9]*\|capture_faults=[0-9]*\|playback_faults=[0-9]*\|out_holes=[0-9/]*\|back_holes=[0-9/]*' | tr '\n' ' '")"
log "dante-sync sync --rate 48000"; "$S" sync --rate 48000 2>&1 | grep -E '^  |k:' | tee -a $D/service-steps.txt
sleep 5; "$S" sync --source usb-aoip 2>&1 | grep -E 'k:' | tee -a $D/service-steps.txt
out=$(settled 48000); log "$out"
work/dante-mode/measure-candidate.sh noise 32 back48d96 > $D/back48d96-noise.out 2>&1
log "48 noise: $(grep -o 'zero runs>=4: [0-9]*' $D/back48d96-noise.out | tail -1)"
work/dante-mode/measure-candidate.sh 32 100 back48d96 > $D/back48d96.out 2>&1
log "48 open: $(grep daw_timeline $D/back48d96.out | tail -1)"
log "service check done"
