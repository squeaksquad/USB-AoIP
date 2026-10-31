#!/bin/zsh
# run-nocap96.sh [SECONDS] [LABEL]: the 96 kHz loaded hour with NO capture (2026-10-31 afternoon, Mac on en7).
# run-catch96.sh without the tcpdump ring and the watcher: the soak on the loop's 8 channels, the owner's
# counters before and after, and the candidate's log copied back for the CHANHOLE and fault count.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=${D:-outputs/latency/rate96-en7-20261031}
SECONDS_SOAK=${1:-3600}
LABEL=${2:-en7nocap96}
P=(-o HostKeyAlias=audio-dev.local)
PI=bdimaio@169.254.92.97
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
counters(){ ssh $P $PI 'l=$(ls -t /dev/shm/dante-owner-*.log | head -1); echo "$l"; grep "^USB t=" $l | tail -1'; }

ssh $P $PI 'sudo -n /usr/local/sbin/usb16x16-dante-catch status | head -1' | sed 's/^/catch: /' | tee -a $D/steps.txt
log "soak $SECONDS_SOAK s at 32 on 8 channels, no capture ($LABEL); owner counters before:"
counters | tee -a $D/steps.txt
USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak $SECONDS_SOAK 32 $LABEL > $D/$LABEL-soak.out 2>&1
log "soak done: $(grep -E '^soak:' $D/$LABEL-soak.out | tail -1); owner counters after:"
counters | tee -a $D/steps.txt
ssh $P $PI "cp \$(ls -t /dev/shm/dante-owner-*.log | head -1) /dev/shm/$LABEL-owner.log"
scp -q $P $PI:/dev/shm/$LABEL-owner.log $D/$LABEL-owner.log
log "owner log copied to $D/$LABEL-owner.log"
