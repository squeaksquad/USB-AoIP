#!/bin/bash
# Replace the installed Dante owner 0facc5ad (rate7, put in by
# install-owner-rate7.sh) with rate8 a15a9d84, and nothing else: the units, the
# plugin, Statime, the configs, transport.conf, the service user, its state and
# the sudo rule are left as they are. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-owner-rate8.sh            install the build pinned below
#   sudo ./install-owner-rate8.sh rollback   put 0facc5ad back
#
# Verifies the new binary against its pinned hash and the installed one
# against the hash it is expected to replace, stops usb16x16-dante.service,
# keeps the old binary as usb16x16-dante-owner.rate8-previous (its own name,
# so the other installers' saved copies are not touched), and starts the
# service again. The outage is the few seconds of the swap plus the unit's own
# start.
#
# 2026-10-28: a15a9d84 is rate7's source with one change (source 6fe705ba):
# while the same refusal of the host's rate stands, the owner writes its rate
# request again after 10 s, then 20, 40 and so on up to 5 minutes, so a
# request the arbiter refused inside its 30 s reversal guard is accepted by
# the first one after it (PROJECT_HANDOFF.md, the FOUND of 11:49 UTC).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
source=$base/owner/usb16x16-dante-owner-rate8
new=a15a9d846254281e965d0da3e4ab57c98b657b97fb7d1f0ba91d53f7cbd63b7f
old=0facc5ad6165b748164148ecc00c5e61a5b5cd22e9f876d217ee1875d7b7f8e4
installed=/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner
previous=$installed.rate8-previous
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
  [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not 0facc5ad; refusing" >&2; exit 4; }
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
[ "$current" = "$old" ] || { echo "the installed owner is $(echo "$current" | cut -c1-8), not the 0facc5ad this replaces; refusing" >&2; exit 4; }

systemctl stop "$unit"
install -o root -g root -m 755 "$installed" "$previous"
install -o root -g root -m 755 "$source" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed $(sha256_of "$installed" | cut -c1-8), kept $(sha256_of "$previous" | cut -c1-8) as $previous"
restart
