#!/bin/bash
# Replace the installed Dante owner 2578c73d (rate5, put in by
# install-owner-rate5.sh) with rate7 0facc5ad, and nothing else: the units, the
# plugin, Statime, the configs, transport.conf, the service user, its state and
# the sudo rule are left as they are. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-owner-rate7.sh            install the build pinned below
#   sudo ./install-owner-rate7.sh rollback   put 2578c73d back
#
# Verifies the new binary against its pinned hash and the installed one
# against the hash it is expected to replace, stops usb16x16-dante.service,
# keeps the old binary as usb16x16-dante-owner.rate7-previous (its own name,
# so the .rate5-previous and the other installers' saved copies are not
# touched), and starts the service again. The outage is the few seconds of the
# swap plus the unit's own start.
#
# 2026-10-28: 0facc5ad is rate5's source with one change (source 7ee7f67f,
# commit 5a10516): while the USB half is open the steward reads the gadget's
# rate controls once a second, and a host rate that differs from the owner's
# hands the USB half back, so the existing closed-half check refuses the
# reopen and writes the rate request. A rate change made on the Mac alone then
# reaches the arbiter. Passed the 48 kHz battery and a Mac-only 48 -> 44.1 ->
# 48 test as a candidate on 2026-10-28 (PROJECT_HANDOFF.md).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
source=$base/owner/usb16x16-dante-owner-rate7
new=0facc5ad6165b748164148ecc00c5e61a5b5cd22e9f876d217ee1875d7b7f8e4
old=2578c73d795f70dd06eedb72a46616ed0e2bd9e8aeae19bcabc003c4a4735d19
installed=/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner
previous=$installed.rate7-previous
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
  [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not 2578c73d; refusing" >&2; exit 4; }
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
[ "$current" = "$old" ] || { echo "the installed owner is $(echo "$current" | cut -c1-8), not the 2578c73d this replaces; refusing" >&2; exit 4; }

systemctl stop "$unit"
install -o root -g root -m 755 "$installed" "$previous"
install -o root -g root -m 755 "$source" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed $(sha256_of "$installed" | cut -c1-8), kept $(sha256_of "$previous" | cut -c1-8) as $previous"
restart
