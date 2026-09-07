#!/bin/bash
# Phase 6 read: the bridge's running floors and gap bar from the Pi, read-only.
# A few KB over ssh (the marker lines and the latest BRIDGE line), no file
# transfer; run it between measurement runs, never during one. Saves the read
# under reads/ beside this script and prices it with gap-bar.py. Optional label
# goes into the file name. The log rotates once at 64 MB (bridge.log.1), so
# both halves are read when the rotated half exists.
set -euo pipefail
label=${1:-read}
dir=$(cd "$(dirname "$0")" && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=$dir/reads/bar-$label-$stamp.txt
mkdir -p "$dir/reads"
ssh bdimaio@192.168.1.201 '
  echo "# read $(date -u +%Y-%m-%dT%H:%M:%SZ) pi: $(uptime)"
  echo "# service: $(systemctl show usb16x16-aes67 -p ActiveEnterTimestamp -p NRestarts | tr "\n" " ")"
  echo "# stage: $(cat /run/usb16x16/stage 2>/dev/null)"
  echo "# recovers file: $(wc -l < /run/usb16x16/recovers 2>/dev/null) lines"
  for f in /run/usb16x16/bridge.log.1 /run/usb16x16/bridge.log; do
    [ -f "$f" ] || continue
    echo "# $f: $(wc -lc < "$f" | tr -s " ") lines bytes, modified $(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ)"
    grep -a "^NEGOTIATED \|^ALIGN \|^PRIMED \|^RECOVER \|^DEPTHSTEP \|^ZERORUN \|^SUMMARY " "$f" || true
  done
  cat /run/usb16x16/last-bridge
' > "$out"
python3 "$dir/gap-bar.py" "$out"
echo "saved ${out#$dir/}"
