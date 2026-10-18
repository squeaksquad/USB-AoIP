#!/bin/zsh
# changeTest.sh MODE TAG: rate change 48 -> 88.2, then alsaloop and a probe.
# X: Pi idle through the change (the gadget sends its fixed idle packets).
# Y: a Pi playback stream of zeros runs through the change (packets sized by the residue logic).
M=$1; T=$2; SP=${0:A:h}
pi() { ssh -o BatchMode=yes bdimaio@192.168.1.201 "$@"; }
pi "pkill -x alsaloop; pkill -x aplay"; sleep 2
$SP/setrate/setrate "USB 16x16" 48000 >/dev/null; sleep 8
if [[ $M == Y ]]; then pi "setsid nohup aplay -q -D hw:UAC2Gadget -f S24_3LE -c 16 -r 48000 -t raw /dev/zero >/dev/null 2>&1 < /dev/null & sleep 1; pgrep -c aplay"; fi
$SP/setrate/setrate "USB 16x16" 88200 >/dev/null; sleep 5
pi "pkill -x aplay; sleep 0.5; setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r 88200 -t 20000 >/dev/shm/rate882/alsaloop-$T.log 2>&1 < /dev/null & sleep 2"
$SP/probe.sh $T
