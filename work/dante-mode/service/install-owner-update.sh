#!/bin/bash
# Replace the installed Dante owner binary with a newer accepted build, and
# nothing else: the units, the plugin, Statime, the configs, the service user,
# its state and the sudo rule are left exactly as install-dante-service.sh
# put them. Run with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-owner-update.sh            install the build pinned below
#   sudo ./install-owner-update.sh rollback   put the previous binary back
#
# Verifies the new binary against its pinned hash and the installed one
# against the hash it is expected to replace, stops usb16x16-dante.service,
# keeps the old binary beside the new as usb16x16-dante-owner.previous, and
# starts the service again (the clock unit is not touched). The outage is the
# few seconds of the swap plus the unit's own start.
#
# 2026-10-11: e392dd71 is 22fd2622's source (e53c8407) with the capture-fault
# fix and the test-only --stall-at (source 437b14fd,
# owner-capture-fault.patch): after a gadget capture overrun the capture is
# started when the holdoff ends, not before it.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
source=$base/owner/usb16x16-dante-owner-fix
new=e392dd7198e18a09dcd8d16b159a8c87d6536fd6e7e22d4dd643c043070dcf6d
old=22fd262211fe2d3b8961d7e268efef35e0d2f5c52f43b0a7c72a992d792a4698
installed=/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner
previous=$installed.previous
unit=usb16x16-dante.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

restart() {
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl start "$unit"
  sleep 12
  echo "$unit is $(systemctl is-active "$unit"); installed owner $(sha256_of "$installed" | cut -c1-8)"
}

# A candidate started by the launcher holds the device the service needs.
if [ "$(systemctl is-active usb16x16-dante-candidate.service 2>/dev/null)" = active ]; then
  echo "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop)" >&2
  exit 5
fi

if [ "${1:-}" = rollback ]; then
  [ -f "$previous" ] || { echo "no previous binary at $previous" >&2; exit 3; }
  systemctl stop "$unit"
  install -o root -g root -m 755 "$previous" "$installed"
  echo "put back $(sha256_of "$installed" | cut -c1-8)"
  restart
  exit 0
fi

[ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
[ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
current=$(sha256_of "$installed")
if [ "$current" = "$new" ]; then
  echo "already installed: $(echo "$new" | cut -c1-8)"
  exit 0
fi
[ "$current" = "$old" ] || { echo "the installed owner is $(echo "$current" | cut -c1-8), not the 22fd2622 this replaces; refusing" >&2; exit 4; }

systemctl stop "$unit"
install -o root -g root -m 755 "$installed" "$previous"
install -o root -g root -m 755 "$source" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed $(sha256_of "$installed" | cut -c1-8), kept $(sha256_of "$previous" | cut -c1-8) as $previous"
restart
