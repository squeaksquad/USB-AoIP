#!/bin/bash
# The traced candidate, then memory activity beside it: a compile, then a large allocation freed.
mark() { L=$(ls -t /dev/shm/dante-owner-*.log | head -1); echo "MARK $1 $(date -u +%T.%3N) owner_t=$(grep "^OWNER" $L | tail -1 | cut -d" " -f2)"; }
sudo -n /usr/local/sbin/usb16x16-dante-candidate start /home/bdimaio/usb-16x16-work/dante-mode/owner/usb16x16-dante-owner-gaptrace --rx-queue 96 --log-every 1 --gap-trace 1500 > /dev/null 2>&1
nice -n 19 python3 /dev/shm/vmstat-watch.py > /dev/shm/vmstat-watch-2.log 2>&1 &
vm=$!
sleep 60; mark quiet-end
cd /home/bdimaio/usb-16x16-work/dante-mode/owner/gaptrace
mark build-begin
g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../../phase4-bridge/include -o ../usb16x16-dante-owner-gaptrace2 main.cpp ../../../phase4-bridge/src/bridge_core.cpp -lasound -lpthread 2>&1 | tail -5
mark build-end
sleep 30; mark alloc-begin
python3 -c "
b=[bytearray(1<<20) for _ in range(450)]
for x in b: x[::4096]=b\"1\"*256
del b"
mark alloc-end
sleep 30; mark cat-begin
cat /usr/lib/aarch64-linux-gnu/*.so* > /dev/null 2>&1
mark cat-end
sleep 30; mark end
kill $vm
L=$(ls -t /dev/shm/dante-owner-*.log | head -1); echo $L
grep -E "LOOPGAP|NETRESYNC" $L
echo DONE
