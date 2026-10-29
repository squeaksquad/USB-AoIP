#!/bin/zsh
# seq-catch.sh [RUNS]: catch one 96 kHz misplaced block on the wire (2026-10-29). A tcpdump ring in the Pi's
# /dev/shm holds the last ~60 s of the Pulse -> Pi flows only (4 x 80 MB, nothing streamed); a watcher on the
# Pi stops it 2 s after the owner's first `SEQ ... point=back ... dropped|repeated` line (candidate rate8seq, --seq-check 8), so the
# capture ends just after the event instead of catching one by chance. The Mac runs `bitexact --loop-channels 8`
# 360 s at a time, at most RUNS times, until the watcher has fired. Needs the operator's `sudo -v`.
# tcpdump runs at nice 19: at normal priority its writes stalled the owner's loop 2 ms (playback faults,
# 15:02 and 15:03 on 2026-10-29, catch1/); an `other` at the stream's start must not fire the trigger either.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-slip-kind-20261029
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
PI=bdimaio@audio-dev.local
RUNS=${1:-4}
ssh $PI 'sudo -n rm -f /dev/shm/seq96.pcap* /dev/shm/seq96-*.txt
log=$(ls -t /dev/shm/dante-owner-*.log | head -1); echo "owner log $log"
sudo -n nohup timeout 2700 nice -n 19 tcpdump -p -i eth0 -n -s 0 -B 32768 -C 80 -W 4 -w /dev/shm/seq96.pcap \
  "udp and src host 169.254.248.189 and dst host 169.254.92.97 and greater 400" > /dev/shm/seq96-tcpdump.txt 2>&1 < /dev/null &
nohup bash -c "tail -n 0 -F $log | grep -m1 -E \"^SEQ .*point=back .*(dropped|repeated) \" > /dev/shm/seq96-trigger.txt; sleep 2; sudo -n pkill -INT -x tcpdump; date -u +%T.%N >> /dev/shm/seq96-trigger.txt" > /dev/null 2>&1 < /dev/null &
sleep 2; pgrep -a tcpdump | head -1'
for run in $(seq $RUNS); do
  T=$(date -u +%Y%m%dT%H%M%SZ); out=outputs/latency/loop8-96catch-bitexact-360s-32f-$T.json
  echo "=== run $run $T"
  "$H" bitexact --device "USB 16x16" --buffer-frames 32 --seconds 360 --loop-channels 8 --output $out > /dev/null 2> ${out%.json}.err
  echo "bitexact exit $? $(head -1 ${out%.json}.err)"
  fired=$(ssh $PI 'cat /dev/shm/seq96-trigger.txt 2>/dev/null')
  if [[ -n $fired ]]; then echo "TRIGGER $fired"; break; fi
done
ssh $PI 'sleep 3; pgrep -x tcpdump >/dev/null && { sudo -n pkill -INT -x tcpdump; echo "stopped by hand"; }; pkill -f "grep -m1 ^SEQ" ; sleep 1; cat /dev/shm/seq96-tcpdump.txt; ls -l --time-style=+%T.%N /dev/shm/seq96.pcap*; sudo -n chmod a+r /dev/shm/seq96.pcap*'
mkdir -p $D/catch && scp -q "$PI:/dev/shm/seq96*" $D/catch/ && ssh $PI 'sudo -n rm -f /dev/shm/seq96.pcap*' && ls -l $D/catch
