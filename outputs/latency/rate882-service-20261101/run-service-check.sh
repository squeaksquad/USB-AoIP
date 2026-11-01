#!/bin/zsh
# run-service-check.sh: after install-dante-rate882.sh, the service at 88.2 moved from the Dante side (dante-sync,
# the arbiter follows): noise probe, three opens of 100 impulses, 120 s soak on 1-8; then back to 48 (noise
# probe, 100 impulses). Dante Switcher's app is quit for the run (its follow would act on the moves).
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate882-service-20261101
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
log(){ echo "$(date -u +%T) $*" | tee -a $D/service-steps.txt; }
# settled RATE: arbiter idle, owner.conf RATE, start check ok with a flow frame rate in that band
settled(){ ssh $P $PI "for i in \$(seq 1 60); do a=\$(systemctl is-active usb16x16-dante-rate); r=\$(grep -o '^RATE=[0-9]*' /etc/usb16x16/dante/owner.conf | cut -d= -f2); s=\$(cat /run/usb16x16-dante-startcheck/status); f=\$(echo \$s | grep -o 'rate=[0-9]*' | cut -d= -f2); case \$a in active|activating) ;; *) if [ \"\${r:-48000}\" = $1 ] && echo \$s | grep -q '^state=ok' && { if [ $1 -gt 80000 ]; then [ \"\${f:-0}\" -gt 10000 ]; else [ \"\${f:-0}\" -gt 5000 ] && [ \"\${f:-0}\" -lt 7000 ]; fi; }; then echo settled after \$((i*5)) s: \$s; exit 0; fi ;; esac; sleep 5; done; echo NOT settled: arbiter \$a RATE=\$r \$s; exit 1"; }
osascript -e 'quit app "DanteSwitcher"' >/dev/null 2>&1; sleep 2; log "Dante Switcher running: $(pgrep -x DanteSwitcher || echo no)"
out=$(settled 48000); rc=$?; log "before: $out"; [ $rc = 0 ] || { open -a DanteSwitcher; exit 1; }
log "dante-sync sync --rate 88200 --allow-band-up"; "$S" sync --rate 88200 --allow-band-up 2>&1 | grep -E '^  |k:|locked' | tee -a $D/service-steps.txt
sleep 5; log "dante-sync sync --source usb-aoip"; "$S" sync --source usb-aoip 2>&1 | grep -E '^  |k:|locked' | tee -a $D/service-steps.txt
out=$(settled 88200); rc=$?; log "$out"
if [ $rc != 0 ]; then log "not settled at 88.2; back to 48"; "$S" sync --rate 48000 2>&1 | grep -E 'k:' | tee -a $D/service-steps.txt; sleep 5; "$S" sync --source usb-aoip >/dev/null 2>&1; open -a DanteSwitcher; exit 1; fi
log "$(ssh $P $PI "journalctl -u usb16x16-dante --since '-5min' --no-pager | grep 'START usb16x16' | tail -1 | grep -o 'rate=88200\|usb_period=[0-9]*\|rx_queue=[0-9]*\|prime_drop=[0-9]*\|capture_drain=[01]' | tr '\n' ' '")"
sleep 180   # the settle after a rate move
work/dante-mode/measure-candidate.sh noise 32 svc882 > $D/svc882-noise.out 2>&1
log "noise: $(grep -o 'zero runs>=4: [0-9]*' $D/svc882-noise.out | tail -1)"
for k in 1 2 3; do
  work/dante-mode/measure-candidate.sh 32 100 svc882-$k > $D/svc882-$k.out 2>&1
  link=$(ssh $P $PI "journalctl -u usb16x16-dante --since '-2min' --no-pager | grep 'USBLINK .*tx=flow' | tail -1 | grep -o 'tx_prime_found=[0-9]* tx_prime_dropped=[0-9]* tx_unanchored=[0-9]*'")
  log "service open $k: $(grep daw_timeline $D/svc882-$k.out | tail -1) | $link"
done
USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak 120 32 svc882 > $D/svc882-soak.out 2>&1
log "soak 120: $(grep -E '^soak:' $D/svc882-soak.out | tail -1)"
log "owner: $(ssh $P $PI "journalctl -u usb16x16-dante --since '-3min' --no-pager | grep 'USB t=' | tail -1 | grep -o 'tx_reprimes=[0-9]*\|capture_faults=[0-9]*\|playback_faults=[0-9]*\|out_holes=[0-9/]*\|back_holes=[0-9/]*' | tr '\n' ' '")"
log "dante-sync sync --rate 48000"; "$S" sync --rate 48000 2>&1 | grep -E '^  |k:|locked' | tee -a $D/service-steps.txt
sleep 5; "$S" sync --source usb-aoip 2>&1 | grep -E 'k:' | tee -a $D/service-steps.txt
out=$(settled 48000); log "$out"
work/dante-mode/measure-candidate.sh noise 32 back48s882 > $D/back48-noise.out 2>&1
log "48 noise: $(grep -o 'zero runs>=4: [0-9]*' $D/back48-noise.out | tail -1)"
work/dante-mode/measure-candidate.sh 32 100 back48s882 > $D/back48.out 2>&1
log "48 open: $(grep daw_timeline $D/back48.out | tail -1)"
open -a DanteSwitcher; log "Dante Switcher relaunched; service check done"
