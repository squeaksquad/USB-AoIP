#!/bin/zsh
# slowwin.sh TAG: the clean slow change (8 s at 48, 5 s after the change), then winprobe.
T=$1; SP=${0:A:h}
pi() { ssh -o BatchMode=yes bdimaio@192.168.1.201 "$@"; }
pi "pkill -x alsaloop"; sleep 2
$SP/setrate/setrate "USB 16x16" 48000 >/dev/null; sleep 8
$SP/setrate/setrate "USB 16x16" 88200 >/dev/null; sleep 5
pi "setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r 88200 -t 20000 >/dev/shm/rate882/alsaloop-$T.log 2>&1 < /dev/null & sleep 2"
$SP/winprobe.sh $T-r882
