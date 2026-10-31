#!/bin/zsh
# run-catch96.sh [SECONDS] [LABEL]: the 96 kHz loaded-hour catch (RATE96_PLAN.md, 2026-10-31).
# Arms a tmpfs ring of the Pulse -> Pi flows on the Pi (usb16x16-dante-catch, nice 19, return only),
# starts watch-chanhole.py beside the candidate's owner log (owner --chan-holes 8), runs the soak on the
# loop's 8 channels, and copies the ring and the trigger back. The ring keeps about the last 60 s; the
# watcher stops it 2 s after the first CHANHOLE event on fewer than 8 channels.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-catch-20261031
SECONDS_SOAK=${1:-3600}
LABEL=${2:-catch96}
PULSE=169.254.248.189
P=(-o HostKeyAlias=audio-dev.local)
PI=bdimaio@169.254.92.97
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }

scp -q $P $D/watch-chanhole.py $PI:/dev/shm/watch-chanhole.py
minutes=$(( SECONDS_SOAK / 60 + 15 ))
log "catch armed: usb16x16-dante-catch start $PULSE return $minutes; watcher on the owner log; soak $SECONDS_SOAK s ($LABEL)"
ssh $P $PI "sudo -n /usr/local/sbin/usb16x16-dante-catch start $PULSE return $minutes &&
  rm -rf /dev/shm/catch96-watch && log=\$(ls -t /dev/shm/dante-owner-*.log | head -1) &&
  nohup python3 -I /dev/shm/watch-chanhole.py \$log /dev/shm/catch96-watch > /dev/shm/catch96-watch.err 2>&1 < /dev/null &
  sleep 1; cat /dev/shm/catch96-watch/trigger.txt" || { log "arming failed"; exit 1; }

USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak $SECONDS_SOAK 32 $LABEL > $D/$LABEL-soak.out 2>&1
log "soak done: $(grep -E '^soak:' $D/$LABEL-soak.out | tail -1)"

ssh $P $PI 'pkill -f watch-chanhole.py; sudo -n /usr/local/sbin/usb16x16-dante-catch stop; cat /dev/shm/catch96-watch/trigger.txt'
mkdir -p $D/$LABEL
scp -q $P "$PI:/dev/shm/catch96-watch/trigger.txt" "$PI:/dev/shm/usb16x16-catch/*.txt" $D/$LABEL/ 2>/dev/null
scp -q $P "$PI:/dev/shm/usb16x16-catch/ring.pcap*" $D/$LABEL/ 2>/dev/null
ls -l $D/$LABEL
log "ring and trigger copied to $D/$LABEL"
