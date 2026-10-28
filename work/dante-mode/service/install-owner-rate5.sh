#!/bin/bash
# Replace the installed Dante owner c8b484ac (rate4, put in by
# install-dante-rate-arbiter.sh) with rate5 2578c73d, and nothing else: the
# units, the plugin, Statime, the configs, transport.conf, the service user,
# its state and the sudo rule are left as they are. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-owner-rate5.sh            install the build pinned below
#   sudo ./install-owner-rate5.sh rollback   put c8b484ac back
#
# Verifies the new binary against its pinned hash and the installed one
# against the hash it is expected to replace, stops usb16x16-dante.service,
# keeps the old binary as usb16x16-dante-owner.rate5-previous (its own name,
# so the .previous and .arbiter-previous that the other installers' rollbacks
# use are not touched), and starts the service again. The outage is the few
# seconds of the swap plus the unit's own start.
#
# 2026-10-28: 2578c73d is rate4's source with one change in service_rx
# (source c52cd9c4, commit 9bff49c): a flowing return direction that sees no
# pull while its queue is already at the limit is re-primed at once, not after
# kIdleWakes, which removed the 44.1 kHz start slips. Passed the 48 kHz
# battery 2026-10-27/28 (PROJECT_HANDOFF.md).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
source=$base/owner/usb16x16-dante-owner-rate5
new=2578c73d795f70dd06eedb72a46616ed0e2bd9e8aeae19bcabc003c4a4735d19
old=c8b484acac083f78c35597e0273f63dabe0544550bc9d942fd495a075a6adb28
installed=/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner
previous=$installed.rate5-previous
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
  [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not c8b484ac; refusing" >&2; exit 4; }
  systemctl stop "$unit"
  install -o root -g root -m 755 "$previous" "$installed.new"
  mv -f "$installed.new" "$installed"
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
[ "$current" = "$old" ] || { echo "the installed owner is $(echo "$current" | cut -c1-8), not the c8b484ac this replaces; refusing" >&2; exit 4; }

systemctl stop "$unit"
install -o root -g root -m 755 "$installed" "$previous"
install -o root -g root -m 755 "$source" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed $(sha256_of "$installed" | cut -c1-8), kept $(sha256_of "$previous" | cut -c1-8) as $previous"
restart
