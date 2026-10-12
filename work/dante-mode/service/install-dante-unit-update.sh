#!/bin/bash
# Replace the installed usb16x16-dante.service unit file with the one that
# waits for eth0's address before starting the owner, and nothing else: the
# owner, the wrapper, owner.conf, the plugin, Statime and its unit are left
# as install-dante-dsp.sh put them. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-unit-update.sh            install the unit pinned below
#   sudo ./install-dante-unit-update.sh rollback   put the previous unit back
#
# Verifies the new unit against its pinned hash and the installed one against
# the hash it is expected to replace, keeps the old unit as
# /usr/local/libexec/usb16x16-dante/usb16x16-dante.service.previous and
# reloads systemd. The running endpoint is NOT restarted: the change is in
# how the unit starts, so it takes effect at the next start and costs no
# outage and no new latency draw now.
#
# 2026-10-12: with eth0 down for 20 s Statime exited, the endpoint restarted
# with it, Inferno aborted three times for want of an IPv4 address and the
# start limit left the unit failed (RESULTS.md, "eth0 down for 20 s"). The
# new unit waits in ExecStartPre until eth0 has an address, without limit.
#
# After this, install-dante-dsp.sh no longer reports "already installed" (it
# pins the unit this replaces); its rollback still goes back to the owner
# and unit from before DSP.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
source=$script_dir/usb16x16-dante-dsp-linkwait.service
new=0f3fabcf14ec64a58cebad86f367355220b9198273e70d392106bfe7a003d795
old=9f5289dd3fbbdd84611c3186d46851c398e925faf0bebd928a0a4a8d441643a9
unit=usb16x16-dante.service
installed=/etc/systemd/system/$unit
previous=/usr/local/libexec/usb16x16-dante/$unit.previous
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

report() {
  systemctl daemon-reload
  echo "$unit is $(systemctl is-active "$unit" || true), not restarted; unit file $(sha256_of "$installed" | cut -c1-8)"
}

if [ "${1:-}" = rollback ]; then
  [ -f "$previous" ] || { echo "no previous unit at $previous" >&2; exit 3; }
  install -o root -g root -m 644 "$previous" "$installed"
  echo "put back $(sha256_of "$installed" | cut -c1-8)"
  report
  exit 0
fi

[ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
[ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
current=$(sha256_of "$installed")
if [ "$current" = "$new" ]; then
  echo "already installed: $(echo "$new" | cut -c1-8)"
  exit 0
fi
[ "$current" = "$old" ] || { echo "the installed unit is $(echo "$current" | cut -c1-8), not the 9f5289dd this replaces; refusing" >&2; exit 4; }

install -o root -g root -m 644 "$installed" "$previous"
install -o root -g root -m 644 "$source" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed $(sha256_of "$installed" | cut -c1-8), kept $(sha256_of "$previous" | cut -c1-8) as $previous"
report
