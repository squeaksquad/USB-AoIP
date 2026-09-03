#!/bin/bash
# One-time, needs the Pi sudo password once. Installs usb16x16-governor.service,
# the boot-time form of stall-tuning lever 1 (governor performance), and
# enables it. Verifies the staged unit against its pinned hash and the
# installed stall-tuning script against the hash install-stall-tuning.sh
# pinned, since the unit calls that script. Does not touch the USB baseline,
# the AES67 service, or the running governor: enabling the unit starts it,
# which writes the same value the runtime lever already holds.
#
#   sudo ./install-governor-unit.sh ./usb16x16-governor.service
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
if [ "$#" -ne 1 ]; then
  echo "usage: $0 GOVERNOR_UNIT" >&2
  exit 2
fi

source=$1
destination=/etc/systemd/system/usb16x16-governor.service
stall_tuning=/usr/local/sbin/usb16x16-stall-tuning
expected_unit_sha256=0064401069c677a2ff2d5d9b05048d5a255277b2893eb462091a587467cae831
expected_stall_tuning_sha256=bde240b8000ee1f91ac8e9ed2c9fc969764a11c47b3f81b2dc2cf8da112cd7c8

if [ "$(sha256sum "$source" | awk '{print $1}')" != "$expected_unit_sha256" ]; then
  echo "unit hash mismatch" >&2
  exit 3
fi
if [ "$(sha256sum "$stall_tuning" | awk '{print $1}')" != "$expected_stall_tuning_sha256" ] ||
   [ "$(stat -c '%U:%G:%a' "$stall_tuning")" != root:root:755 ]; then
  echo "installed stall-tuning script is not the pinned one; run install-stall-tuning.sh first" >&2
  exit 4
fi
systemd-analyze verify "$source" 2>&1 | grep -v "^$" || true

install -o root -g root -m 644 "$source" "$destination"
systemctl daemon-reload
systemctl enable --now usb16x16-governor.service

echo "installed $destination ($expected_unit_sha256)"
echo "enabled and started; governor now: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo "rollback: sudo systemctl disable --now usb16x16-governor.service (puts ondemand back)"
