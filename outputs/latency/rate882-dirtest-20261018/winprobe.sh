#!/bin/zsh
# winprobe.sh TAG: a noise probe with a 3 s per-packet trace window 12 s into it.
T=$1; SP=${0:A:h}
$SP/probe.sh $T & h=$!
sleep 12; ssh -o BatchMode=yes bdimaio@192.168.1.201 "echo '3 $T' > /dev/shm/rate882/window"
wait $h
