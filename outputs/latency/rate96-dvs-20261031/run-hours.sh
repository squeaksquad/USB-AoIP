#!/bin/zsh
# run-hours.sh: two 96 kHz hours without capture, DVS running (2026-10-31 evening). Hour 2 on the running
# candidate (preset dsp-loaded@96000); then the candidate restarted with no preset and hour 3 (direct), where
# the soak's verdict is a real PASS/FAIL. No rate move between them. Noise probe at 32 before each.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
export D=outputs/latency/rate96-dvs-20261031
R=outputs/latency/rate96-en7-20261031/run-nocap96.sh
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97; B=/home/bdimaio/usb-16x16-work/dante-mode
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
probe(){ work/dante-mode/measure-candidate.sh noise 32 $1 > $D/$1-noise.out 2>&1; log "noise probe $1: $(grep -oE 'zero runs>=4: [0-9]+' $D/$1-noise.out)"; }

probe dvs96preset
$R 3600 dvs96preset
ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-candidate stop > /dev/null 2>&1; sleep 3;
  sudo -n /usr/local/sbin/usb16x16-dante-candidate start $B/owner/usb16x16-dante-owner-chanholes CONFIG=$B/config/asound-inferno-owner-rate96-usb-aoip.conf --seconds 0 --rate 96000 --period 64 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192 --chan-holes 8 --event-trace > /dev/shm/cand-start.txt 2>&1 < /dev/null; cat /dev/shm/cand-start.txt" | tee -a $D/steps.txt
log "candidate restarted with no preset (direct), same arguments otherwise"
sleep 60
probe dvs96direct
$R 3600 dvs96direct
log "both hours done"
