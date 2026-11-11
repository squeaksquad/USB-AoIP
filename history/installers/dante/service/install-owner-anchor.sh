#!/bin/bash
# The deterministic round trip (work/mac-driver-spike/SPIKE_PLAN.md, Phases B and C,
# 2026-10-30): replace the installed owner a15a9d84 (rate8) with abee374a, the start
# wrapper a6c3a197 with f4afa51d (two more transport keys, PRIME_DROP and
# CAPTURE_DRAIN) and transport.conf 1434f79f with 31a2a257 (the same plus
# PRIME_DROP=24, CAPTURE_DRAIN=1), together. The units, the plugin, Statime, the
# Inferno config, owner.conf, the service user, its state and the sudo rules are left
# as they are. Run with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-owner-anchor.sh            install the three files pinned below
#   sudo ./install-owner-anchor.sh rollback   put a15a9d84, a6c3a197 and 1434f79f back
#
# Every file is checked against its pinned hash and every installed one against the
# hash it is expected to replace; usb16x16-dante.service is stopped for the swap, the
# old files are kept beside the new ones as *.anchor-previous, and the service is
# started again.
#
# abee374a is a15a9d84's source plus --prime-drop D (the outgoing prime drops a constant
# D of the host's first block and commits the rest at the pointer as it stands),
# --capture-drain (the gadget capture PCM is restarted when the host stops sending, so
# the next session starts from an empty ring on a period boundary, and a depth one short
# of the lead at the prime waits a block), and the --impulse-trace/--open-phase
# diagnostics. With PRIME_DROP=24 and CAPTURE_DRAIN=1 the host-driver spike read 374 or
# 375 on 24 of 24 opens and the class driver's daw_timeline 532 on 8 of 8.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
libexec=/usr/local/libexec/usb16x16-dante
unit=usb16x16-dante.service
#            installed path                          source                                     new                                                               old
files=(
  "$libexec/usb16x16-dante-owner"          "$base/owner/usb16x16-dante-owner-wait127"   abee374a09d182064480cfa3a733defdbaced7f014cb6e95ef7f0b3e6f986b8e a15a9d846254281e965d0da3e4ab57c98b657b97fb7d1f0ba91d53f7cbd63b7f
  "$libexec/usb16x16-dante-start"          "$script_dir/usb16x16-dante-start-transport" f4afa51d4fef13baa7fdfe7cc6fa56c12e37c8b5ffe6d6a638a4ab7466dc78eb a6c3a1972ca6bbad335194dee436b1a611e84c7918b4e126a1f48650570e13f6
  "/etc/usb16x16/dante/transport.conf"     "$script_dir/transport-anchor.conf"          31a2a257a5dd5b67ed3954dcf0808e296c2a86a88e411a1b5a3dc13bce87cb6f 1434f79f7d5c4d0c877a0f7a1bcd6732db98b8096c1793df50952c119c09a105
)
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
mode_of() { case "$1" in *.conf) echo 644 ;; *) echo 755 ;; esac; }

restart() {
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl start "$unit"
  sleep 12
  echo "$unit is $(systemctl is-active "$unit"); owner $(sha256_of "$libexec/usb16x16-dante-owner" | cut -c1-8)," \
       "start $(sha256_of "$libexec/usb16x16-dante-start" | cut -c1-8), transport.conf $(sha256_of /etc/usb16x16/dante/transport.conf | cut -c1-8)"
}

if [ "$(systemctl is-active usb16x16-dante-candidate.service 2>/dev/null)" = active ]; then
  echo "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop)" >&2
  exit 5
fi

if [ "${1:-}" = rollback ]; then
  for ((i = 0; i < ${#files[@]}; i += 4)); do
    installed=${files[i]} old=${files[i+3]}
    [ -f "$installed.anchor-previous" ] || { echo "no $installed.anchor-previous" >&2; exit 3; }
    [ "$(sha256_of "$installed.anchor-previous")" = "$old" ] || { echo "$installed.anchor-previous is not ${old:0:8}; refusing" >&2; exit 4; }
  done
  systemctl stop "$unit"
  for ((i = 0; i < ${#files[@]}; i += 4)); do
    installed=${files[i]}
    install -o root -g root -m "$(mode_of "$installed")" "$installed.anchor-previous" "$installed.new"
    mv -f "$installed.new" "$installed"
  done
  echo "put back the three previous files"
  restart
  exit 0
fi

already=1
for ((i = 0; i < ${#files[@]}; i += 4)); do
  installed=${files[i]} source=${files[i+1]} new=${files[i+2]} old=${files[i+3]}
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
  current=$(sha256_of "$installed")
  [ "$current" = "$new" ] && continue
  already=0
  [ "$current" = "$old" ] || { echo "$installed is ${current:0:8}, not the ${old:0:8} this replaces; refusing" >&2; exit 4; }
done
[ "$already" -eq 0 ] || { echo "already installed"; exit 0; }

systemctl stop "$unit"
for ((i = 0; i < ${#files[@]}; i += 4)); do
  installed=${files[i]} source=${files[i+1]} new=${files[i+2]}
  [ "$(sha256_of "$installed")" = "$new" ] && continue
  install -o root -g root -m "$(mode_of "$installed")" "$installed" "$installed.anchor-previous"
  install -o root -g root -m "$(mode_of "$installed")" "$source" "$installed.new"
  mv -f "$installed.new" "$installed"
done
echo "installed; previous files kept as *.anchor-previous"
restart
