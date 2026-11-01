#!/bin/zsh
# run-battery-d48.sh: the 96 kHz battery on candidate c84e6a36 arm A with --prime-drop 48 --capture-drain (2026-10-31).
# noise probe, four loaded 800-impulse runs, 600 s 8-channel soak, bitexact --loop-channels 8 360 s.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-primedrop-20261031
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
P=(-o HostKeyAlias=audio-dev.local); PI=bdimaio@169.254.92.97
log(){ echo "$(date -u +%T) $*" | tee -a $D/steps.txt; }
counters(){ ssh $P $PI 'l=$(ls -t /dev/shm/dante-owner-*.log | head -1); grep "^USB t=" $l | tail -1'; }
log "battery at 96 under the service; owner counters:"; counters | tee -a $D/steps.txt
work/dante-mode/measure-candidate.sh noise 32 d48b96 > $D/d48b96-noise.out 2>&1
log "noise: $(grep -o 'zero runs>=4: [0-9]*' $D/d48b96-noise.out | tail -1)"
for i in 1 2 3 4; do
  USB16X16_OTHER_LOAD=0.1 work/dante-mode/measure-candidate.sh 32 800 d48b96loaded$i > $D/d48b96loaded$i.out 2>&1
  log "loaded$i: $(grep daw_timeline $D/d48b96loaded$i.out | tail -1)"
done
USB16X16_LOOP_CHANNELS=8 work/dante-mode/measure-candidate.sh soak 600 32 d48b96 > $D/d48b96-soak.out 2>&1
log "soak 600: $(grep -E '^soak:' $D/d48b96-soak.out | tail -1) / $(grep -E '^rate=' $D/d48b96-soak.out | tail -1)"
T=$(date -u +%Y%m%dT%H%M%SZ); out=outputs/latency/d48b96-bitexact-360s-32f-$T.json
USB16X16_DEVICE=${USB16X16_DEVICE:-USB-AoIP}
"$H" bitexact --device "$USB16X16_DEVICE" --buffer-frames 32 --seconds 360 --loop-channels 8 --output $out > $D/d48b96-bitexact.out 2> ${out%.json}.err
log "bitexact exit $?: $out"; tail -5 ${out%.json}.err | tee -a $D/steps.txt
log "owner counters after:"; counters | tee -a $D/steps.txt
log "battery done"
