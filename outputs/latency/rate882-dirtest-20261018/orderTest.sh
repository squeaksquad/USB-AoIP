#!/bin/zsh
# orderTest.sh MODE TAG. a = Pi alsaloop running before the Mac stream starts; b = Mac stream first, then alsaloop.
M=$1; T=$2; SP=${0:A:h}
pi() { ssh -o BatchMode=yes bdimaio@192.168.1.201 "$@"; }
start_loop() { pi "setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r 88200 -t 20000 >/dev/shm/rate882/alsaloop-$T.log 2>&1 < /dev/null & sleep 2"; }
pi "pkill -x alsaloop"; sleep 12            # Mac stream idle, coreaudiod lets the engine stop
if [[ $M == a ]]; then start_loop; sleep 5; fi
$SP/setrate/hold "USB 16x16" 75 >/dev/null & h=$!
sleep 4
if [[ $M == b ]]; then start_loop; sleep 3; fi
$SP/probe.sh $T
kill $h 2>/dev/null; wait $h 2>/dev/null
