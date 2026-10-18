#!/bin/zsh
# quickY.sh TAG: the failing quick change, but a Pi zeros stream (aplay) bridges it so the gadget never idles.
T=$1; SP=${0:A:h}
pi() { ssh -o BatchMode=yes bdimaio@192.168.1.201 "$@"; }
$SP/loopprobe.sh 48000 $T-r48 | tail -1 | cut -c1-60
pi "pkill -x alsaloop; setsid nohup aplay -q -D hw:UAC2Gadget -f S24_3LE -c 16 -r 48000 -t raw /dev/zero >/dev/null 2>&1 < /dev/null & sleep 0.3"
$SP/setrate/setrate "USB 16x16" 88200 >/dev/null
pi "pkill -x aplay; setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r 88200 -t 20000 >/dev/shm/rate882/alsaloop-$T.log 2>&1 < /dev/null & sleep 2"
$SP/probe.sh $T-r882
