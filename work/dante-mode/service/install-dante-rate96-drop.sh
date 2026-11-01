#!/bin/bash
# The prime drop and capture drain at 96 kHz (RATE96_PLAN.md, after phase 5): one
# file, transport.conf, 082ce171 (install-dante-rate96.sh's) for 6498b9f4, whose only
# change is PRIME_DROP_96000=48 and CAPTURE_DRAIN_96000=1, so every Mac open at 96
# draws the same round trip (958 on six of six opens in the 2026-10-31 sweep). The
# 48 and 44.1 command lines are unchanged. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate96-drop.sh            install transport.conf 6498b9f4
#   sudo ./install-dante-rate96-drop.sh rollback   put 082ce171 back
#
# Keeps the old file as /usr/local/libexec/usb16x16-dante/transport.conf.rate96drop-previous.
# The owner reads transport.conf only when it starts, so this restarts
# usb16x16-dante (a short outage, at whatever rate it runs). Its rollback comes
# before install-dante-rate96.sh's.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
source_file=$script_dir/transport-rate96-drop.conf
new=6498b9f49134fdf08cbea66c68ec060a6dce9ef9a54e506cccb73c6dfa29356a
old=082ce171e67af0ebb1306d014819e772cb3ba8d7200e66723c1516457e8cabf3
installed=/etc/usb16x16/dante/transport.conf
kept=/usr/local/libexec/usb16x16-dante/transport.conf.rate96drop-previous
unit=usb16x16-dante.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

restart() {
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl restart "$unit"
  sleep 12
  echo "$unit is $(systemctl is-active "$unit"); transport.conf $(sha256_of "$installed" | cut -c1-8)"
}

if [ "$(systemctl is-active usb16x16-dante-candidate.service 2>/dev/null)" = active ]; then
  echo "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop)" >&2
  exit 5
fi

if [ "${1:-}" = rollback ]; then
  [ -f "$kept" ] || { echo "no previous file at $kept" >&2; exit 3; }
  [ "$(sha256_of "$kept")" = "$old" ] || { echo "$kept is not 082ce171; refusing" >&2; exit 4; }
  install -o root -g root -m 644 "$kept" "$installed.new"
  mv -f "$installed.new" "$installed"
  echo "put back transport.conf 082ce171"
  restart
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [rollback]" >&2; exit 2; }

[ -r "$source_file" ] || { echo "missing source: $source_file" >&2; exit 3; }
[ "$(sha256_of "$source_file")" = "$new" ] || { echo "hash mismatch: $source_file" >&2; exit 4; }
now=$(sha256_of "$installed")
if [ "$now" = "$new" ]; then
  echo "already installed"
  exit 0
fi
[ "$now" = "$old" ] || { echo "the installed transport.conf is ${now:0:8}, not the 082ce171 this replaces; refusing" >&2; exit 4; }

install -o root -g root -m 644 "$installed" "$kept"
install -o root -g root -m 644 "$source_file" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed transport.conf $(sha256_of "$installed" | cut -c1-8); kept the old one as $kept"
restart
