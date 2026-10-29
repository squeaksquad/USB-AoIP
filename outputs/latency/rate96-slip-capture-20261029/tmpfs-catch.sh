#!/bin/zsh
# tmpfs-catch.sh [TRIES] [SECONDS]: catch one 96 kHz bitexact slip in a short eth0 capture that
# stays on the Pi (2026-10-29). A streamed capture loads the Pi enough to break the loop
# (RATE96_PLAN.md, FOUND 10:39-11:15), so this writes the whole run (100 MB files, at most 40 s, about 430 MB) to /dev/shm instead,
# runs bitexact for SECONDS inside it, and copies the ring to the Mac only after a run with a
# slip; a run without one is deleted. First a host-gain check under the capture, so a capture
# that still breaks the loop says so before any bitexact. Needs the operator's `sudo -v`.
set -u
cd /Users/bryandimaio/Development/USB-AoIP
D=outputs/latency/rate96-slip-capture-20261029
H="work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
TRIES=${1:-6} SECS=${2:-30}
PI=bdimaio@audio-dev.local
start_cap() {
  ssh $PI 'sudo -n rm -f /dev/shm/slip96.pcap*; sudo -n nohup timeout 40 tcpdump -p -i eth0 -n -s 0 -B 32768 -C 100 -w /dev/shm/slip96.pcap "udp and host 169.254.248.189 and greater 400" > /dev/shm/slip96-tcpdump.txt 2>&1 < /dev/null & echo started'
}
stop_cap() { ssh $PI 'sudo -n pkill -INT -x tcpdump; sleep 1; cat /dev/shm/slip96-tcpdump.txt; ls -l --time-style=+%T /dev/shm/slip96.pcap*'; }

echo "=== hostgain under the tmpfs capture $(date -u +%T)"
start_cap; sleep 3
for i in 1 2 3; do "$H" hostgain --device "USB 16x16" --buffer-frames 32 --loop-channels 8 2>&1 | grep -i 'error\|"inputGain' | head -1; done
stop_cap
ssh $PI 'sudo -n rm -f /dev/shm/slip96.pcap*'

for try in $(seq $TRIES); do
  T=$(date -u +%Y%m%dT%H%M%SZ); out=outputs/latency/loop8-96-bitexact-tmpfs-${SECS}s-32f-$T.json
  echo "=== try $try $T"
  start_cap; sleep 2
  "$H" bitexact --device "USB 16x16" --buffer-frames 32 --seconds $SECS --loop-channels 8 --output $out > /dev/null 2> ${out%.json}.err
  rc=$?
  stop_cap
  echo "bitexact exit $rc $(head -1 ${out%.json}.err)"
  [[ -f $out ]] || { ssh $PI 'sudo -n rm -f /dev/shm/slip96.pcap*'; continue; }
  lost=$(python3 -c "import json,sys; d=json.load(open('$out')); c=d['channels'][0]; print(c['lostLocks'], c['lastLostLockFrame']/d['sampleRate'])")
  echo "ch1 lostLocks, last at s: $lost"
  if [[ ${lost%% *} -gt 0 ]]; then
    mkdir -p $D/try-$T
    ssh $PI 'sudo -n chmod a+r /dev/shm/slip96.pcap*'
    scp -q "$PI:/dev/shm/slip96.pcap*" $D/try-$T/ && ssh $PI 'sudo -n rm -f /dev/shm/slip96.pcap*'
    ls -l $D/try-$T; echo "CAUGHT $out"; exit 0
  fi
  ssh $PI 'sudo -n rm -f /dev/shm/slip96.pcap*'
done
echo "no slip in $TRIES tries"
