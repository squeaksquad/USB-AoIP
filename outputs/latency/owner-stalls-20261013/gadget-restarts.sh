#!/bin/bash
# N gadget restarts SPACING s apart, each stamped.
for i in $(seq 1 ${1:-24}); do
  echo "RESTART $i begin $(date -u +%FT%T.%3NZ)"
  sudo -n /usr/bin/systemctl restart usb-16x16.service
  sleep ${2:-20}
done
echo DONE
