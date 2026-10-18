#!/bin/zsh
# quickwin.sh TAG: the failing quick change 48 -> 88.2, then winprobe.
T=$1; SP=${0:A:h}
$SP/loopprobe.sh 48000 $T-r48 | tail -1 | cut -c1-70
ssh -o BatchMode=yes bdimaio@192.168.1.201 "pkill -x alsaloop"
$SP/setrate/setrate "USB 16x16" 88200 >/dev/null
ssh -o BatchMode=yes bdimaio@192.168.1.201 "setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r 88200 -t 20000 >/dev/shm/rate882/alsaloop-$T.log 2>&1 < /dev/null & sleep 2"
$SP/winprobe.sh $T-r882
