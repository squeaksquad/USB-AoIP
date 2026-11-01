#!/bin/zsh
# run-macrule.sh: does the macOS 88.2 silent state still happen on today's kernel and macOS?
# The service stopped, a USB-only alsaloop on the Pi; the October quick change (set 88.2,
# loop restarted, probe about 3.5 s after the set) from 48 and from 44.1, three each, each
# preceded by a clean probe at the start rate after a 10 s settle; then the slow change.
# Dante Switcher's app is quit for the run (its follow would move the network).
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
quick882() { pi "pkill -x alsaloop"; sleep 1; log "$($D/setrate USB-AoIP 88200)"; loop 88200 $1; probe $1; }

log "start; Dante Switcher quit: $(osascript -e 'quit app "DanteSwitcher"' 2>&1; sleep 2; pgrep -x DanteSwitcher || echo yes)"
log "service: $(pi 'systemctl is-active usb16x16-dante-rate.service; cat /run/usb16x16-dante-startcheck/status')"
pi "sudo -n systemctl stop usb16x16-dante; mkdir -p /dev/shm/rate882m"; log "service stopped"
for i in 1 2 3; do settle_to 48000 from48-$i-r48; quick882 from48-$i-r882quick; done
for i in 1 2 3; do settle_to 44100 from441-$i-r441; quick882 from441-$i-r882quick; done
pi "pkill -x alsaloop"; sleep 1; $D/setrate USB-AoIP 48000 >/dev/null; sleep 10
log "$($D/setrate USB-AoIP 88200)"; sleep 10; loop 88200 slow-r882; probe slow-r882
pi "pkill -x alsaloop"; sleep 1; log "$($D/setrate USB-AoIP 48000)"; sleep 10
pi "sudo -n systemctl start usb16x16-dante"
for t in $(seq 60); do sleep 5; s=$(pi 'cat /run/usb16x16-dante-startcheck/status 2>/dev/null'); [[ $s == state=ok* && $(pi 'systemctl is-active usb16x16-dante') == active ]] && break; done
log "service started: $s"
open -a DanteSwitcher; sleep 3; log "Dante Switcher relaunched: $(pgrep -x DanteSwitcher)"
log "done"
