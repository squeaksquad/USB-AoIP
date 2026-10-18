#!/bin/zsh
# probe.sh TAG: one noise probe at 32 against whatever is running.
T=$1; cd "/Users/bryandimaio/Development/USB 16x16"; D=outputs/latency/rate882-dirtest-20261018; S=$D/$T-noise-ch2-32f
USB16X16_DUMP=$S.raw "work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency" measure --device "USB 16x16" --buffer-frames 32 --output-channel 1 --input-channel 2 --other-channel-load-amplitude 0.1 --impulses 100 --maximum-lag-ms 200 --output $S.json >/dev/null 2>$S.log
print "$T exit=$? $(python3 outputs/latency/usb-holes-20260904/zeros.py $S.raw 32 | tee $S.zeros.txt | head -1 | sed 's/.*zeros inside span/zeros/; s/, mean run/ mean/; s/, run-length.*//')"
rm -f $S.raw $S.raw.markers
