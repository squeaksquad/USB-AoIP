#!/bin/zsh
# loopprobe.sh RATE TAG: restart Pi alsaloop at RATE (Mac set first), one noise probe at 32.
R=$1; T=$2; SP=${0:A:h}; cd "/Users/bryandimaio/Development/USB 16x16"
D=outputs/latency/rate882-dirtest-20261018; S=$D/$T-noise-ch2-32f
ssh -o BatchMode=yes bdimaio@192.168.1.201 "pkill -x alsaloop; sleep 1"
$SP/setrate/setrate "USB 16x16" $R
ssh -o BatchMode=yes bdimaio@192.168.1.201 "setsid nohup alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r $R -t 20000 -v >/dev/shm/rate882/alsaloop-$T.log 2>&1 < /dev/null & sleep 2; pgrep -c alsaloop"
USB16X16_DUMP=$S.raw "work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency" measure --device "USB 16x16" --buffer-frames 32 --output-channel 1 --input-channel 2 --other-channel-load-amplitude 0.1 --impulses 100 --maximum-lag-ms 200 --output $S.json >/dev/null 2>$S.log
print "$T rate=$R exit=$?"
python3 outputs/latency/usb-holes-20260904/zeros.py $S.raw 32 | tee $S.zeros.txt | head -1
rm -f $S.raw $S.raw.markers
