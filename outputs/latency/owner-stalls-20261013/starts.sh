#!/bin/bash
# N candidate starts of BINARY, each left SECONDS, LOOPGAP lines collected.
bin=$1; n=${2:-8}; secs=${3:-35}
for i in $(seq 1 $n); do
  sudo -n /usr/local/sbin/usb16x16-dante-candidate stop; sleep 2
  sudo -n /usr/local/sbin/usb16x16-dante-candidate start /home/bdimaio/usb-16x16-work/dante-mode/owner/$bin --rx-queue 96 --log-every 1 --gap-trace 1500 > /dev/null 2>&1
  sleep $secs
  L=$(ls -t /dev/shm/dante-owner-*.log | head -1)
  echo "START $i $bin $L gaps=$(grep -c LOOPGAP $L) resyncs=$(grep -c NETRESYNC $L)"
  grep LOOPGAP $L
done
sudo -n /usr/local/sbin/usb16x16-dante-candidate stop
echo DONE
