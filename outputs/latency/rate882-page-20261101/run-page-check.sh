#!/bin/zsh
# run-page-check.sh: the 88.2 counterpart of dsp96-page-20261101. The transparent verify preset "Rate check"
# compiled the page's way (build-request.mjs) and queued by usb16x16-web's own write_apply_request (queue.py);
# then the Mac's USB-AoIP to 88.2 by setrate (the Pro Tools case: the owner refuses the reopen and asks the
# arbiter), the domain after it by dante-sync --source usb-aoip; noise probe, three opens, 120 s soak on 1-8 with
# the preset's @88200 file; back to 48 the same way; then direct and remove; 100 impulses at 48.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate882-page-20261101
S="$HOME/Development/Dante Switcher/.build/debug/dante-sync"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
W=/home/bdimaio/usb-16x16-work/web-apply
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
pi(){ ssh $P $PI "$@"; }
# moved RATE: the arbiter idle with owner.conf at RATE (the domain is moved after it, so no flows yet)
moved(){ pi "for i in \$(seq 1 60); do a=\$(systemctl is-active usb16x16-dante-rate); r=\$(grep -o '^RATE=[0-9]*' /etc/usb16x16/dante/owner.conf | cut -d= -f2); case \$a in active|activating) ;; *) [ \"\${r:-48000}\" = $1 ] && { echo arbiter moved after \$((i*2)) s; exit 0; } ;; esac; sleep 2; done; echo NOT moved: RATE=\$r; exit 1"; }
settled(){ pi "for i in \$(seq 1 60); do a=\$(systemctl is-active usb16x16-dante-rate); r=\$(grep -o '^RATE=[0-9]*' /etc/usb16x16/dante/owner.conf | cut -d= -f2); s=\$(cat /run/usb16x16-dante-startcheck/status); f=\$(echo \$s | grep -o 'rate=[0-9]*' | cut -d= -f2); case \$a in active|activating) ;; *) if [ \"\${r:-48000}\" = $1 ] && echo \$s | grep -q '^state=ok' && { if [ $1 -gt 80000 ]; then [ \"\${f:-0}\" -gt 10000 ]; else [ \"\${f:-0}\" -gt 5000 ] && [ \"\${f:-0}\" -lt 7000 ]; fi; }; then echo settled after \$((i*5)) s: \$s; exit 0; fi ;; esac; sleep 5; done; echo NOT settled: arbiter \$a RATE=\$r \$s; exit 1"; }
receipt(){ pi "for i in \$(seq 1 90); do f=$W/receipts/$1.json; if [ -f \$f ] && grep -q '\"state\": \"\(done\|failed\|refused\|rolled-back\)\"' \$f; then grep -o '\"state\": \"[a-z]*\"' \$f | tail -1; grep -o '\"error\": [^,]*' \$f | head -1; exit 0; fi; sleep 2; done; echo receipt $1 not finished"; }
conf(){ pi "grep -E '^(RATE|DSP_PRESET|DSP_SHA256|DSP_LIVE|METERS)=' /etc/usb16x16/dante/owner.conf | tr '\n' ' '"; }
journal(){ pi "journalctl -u usb16x16-dante --since '$1' --no-pager | grep -E 'USBRATE|DSP loaded|START usb16x16|USBOPEN' | cut -c1-330"; }
osascript -e 'quit app "DanteSwitcher"' >/dev/null 2>&1; sleep 2; log "Dante Switcher running: $(pgrep -x DanteSwitcher || echo no)"
out=$(settled 48000); rc=$?; log "before: $out | $(conf)"; [ $rc = 0 ] || { open -a DanteSwitcher; exit 1; }
scp -q $P $D/req.json $D/queue.py $PI:/dev/shm/
id=$(pi "python3 /dev/shm/queue.py /dev/shm/req.json dante-rate-check preset"); log "preset queued: $id"
log "receipt $id: $(receipt $id | tr '\n' ' ')"; out=$(settled 48000); log "$out | $(conf)"
t0=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
log "Mac USB-AoIP to 88.2: $($D/setrate USB-AoIP 88200)"
log "$(moved 88200) | $(conf)"
log "dante-sync sync --source usb-aoip --allow-band-up"; "$S" sync --source usb-aoip --allow-band-up 2>&1 | grep -E '^  |k:|locked|abort' | tee -a $D/steps.txt
out=$(settled 88200); rc=$?; log "$out"
journal "$t0" | tee -a $D/steps.txt
[ $rc = 0 ] || log "NOT at 88.2; measuring anyway is pointless"
if [ $rc = 0 ]; then
  sleep 180
  work/dante-mode/measure-candidate.sh noise 32 page882 > $D/noise.out 2>&1; log "noise: $(grep -o 'zero runs>=4: [0-9]*' $D/noise.out | tail -1)"
  for k in 1 2 3; do work/dante-mode/measure-candidate.sh 32 100 page882-$k > $D/open-$k.out 2>&1; log "open $k: $(grep daw_timeline $D/open-$k.out | tail -1)"; done
  USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak 120 32 page882 > $D/soak.out 2>&1; log "soak 120: $(grep -E '^soak:' $D/soak.out | tail -1)"
  log "owner: $(pi "journalctl -u usb16x16-dante --since '-3min' --no-pager | grep 'USB t=' | tail -1 | grep -o 'dsp_us_max=[0-9]*\|tx_reprimes=[0-9]*\|capture_faults=[0-9]*\|playback_faults=[0-9]*\|out_holes=[0-9/]*\|back_holes=[0-9/]*' | tr '\n' ' '")"
fi
t1=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
log "Mac USB-AoIP to 48: $($D/setrate USB-AoIP 48000)"
log "$(moved 48000) | $(conf)"
"$S" sync --source usb-aoip 2>&1 | grep -E '^  |k:|locked' | tee -a $D/steps.txt
journal "$t1" | tee -a $D/steps.txt
out=$(settled 48000); log "$out"
id=$(pi "python3 /dev/shm/queue.py - direct profile dante-rate-check"); log "direct queued: $id; $(receipt $id | tr '\n' ' ')"
out=$(settled 48000); log "$out"
id=$(pi "python3 /dev/shm/queue.py - dante-rate-check remove rate-check"); log "remove queued: $id; $(receipt $id | tr '\n' ' ')"
log "after: $(conf) | dsp files: $(pi 'ls /etc/usb16x16/dsp/ | grep -c dante-' )"
out=$(settled 48000); log "$out"
work/dante-mode/measure-candidate.sh 32 100 page882-restored > $D/restored.out 2>&1; log "restored direct at 48: $(grep daw_timeline $D/restored.out | tail -1)"
pi "cp $W/receipts/*.json /dev/shm/ 2>/dev/null; rm -f /dev/shm/req.json /dev/shm/queue.py"
open -a DanteSwitcher; log "Dante Switcher relaunched; page check done"
