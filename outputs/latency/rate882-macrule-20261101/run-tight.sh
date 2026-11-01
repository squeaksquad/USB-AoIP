#!/bin/zsh
# run-tight.sh: the tighter case, nearer a DAW opening a session: the harness opens USB-AoIP about 0.3 s
# after the 88.2 set (the Pi's loop restarted in parallel, up about 2 s later), three from 48, three from 44.1.
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate882-macrule-20261101; L=$D/steps.txt
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
pi() { ssh -o HostKeyAlias=audio-dev.local -o BatchMode=yes bdimaio@169.254.92.97 "$@"; }
log() { print "$(date -u +%H:%M:%S) $*" | tee -a $L; }
loop() { pi "pkill -x alsaloop; sleep 1; setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r $1 -t 20000 >/dev/shm/rate882m/alsaloop-$2.log 2>&1 < /dev/null & sleep 2; pgrep -c alsaloop" >/dev/null; }
probe() {
  local S=$D/$1-noise-ch2-32f
  USB16X16_DUMP=$S.raw "$H" measure --device USB-AoIP --buffer-frames 32 --output-channel 1 --input-channel 2 --other-channel-load-amplitude 0.1 --impulses 100 --maximum-lag-ms 200 --output $S.json >/dev/null 2>$S.log
  local rc=$?
  log "$1 exit=$rc $(python3 outputs/latency/usb-holes-20260904/zeros.py $S.raw 32 | tee $S.zeros.txt | head -1)"
  rm -f $S.raw $S.raw.markers
}
settle_to() { pi "pkill -x alsaloop"; sleep 1; $D/setrate USB-AoIP $1 >/dev/null; sleep 10; loop $1 $2; probe $2; }
tight882() { pi "pkill -x alsaloop"; sleep 1; $D/setrate USB-AoIP 88200 > $D/.set.txt & sleep 0.3; loop 88200 $1 & probe $1; wait; log "$(cat $D/.set.txt)"; }
log "tight: start; Dante Switcher quit: $(osascript -e 'quit app "DanteSwitcher"' 2>&1; sleep 2; pgrep -x DanteSwitcher || echo yes)"
log "service: $(pi 'systemctl is-active usb16x16-dante-rate.service; cat /run/usb16x16-dante-startcheck/status')"
pi "sudo -n systemctl stop usb16x16-dante; mkdir -p /dev/shm/rate882m"; log "service stopped"
for i in 1 2 3; do settle_to 48000 t48-$i-r48; tight882 t48-$i-r882tight; done
for i in 1 2 3; do settle_to 44100 t441-$i-r441; tight882 t441-$i-r882tight; done
pi "pkill -x alsaloop"; sleep 1; log "$($D/setrate USB-AoIP 48000)"; sleep 10
pi "sudo -n systemctl start usb16x16-dante"
for t in $(seq 60); do sleep 5; s=$(pi 'cat /run/usb16x16-dante-startcheck/status 2>/dev/null'); [[ $s == state=ok* && $(pi 'systemctl is-active usb16x16-dante') == active ]] && break; done
log "service started: $s"
log "tight done"
