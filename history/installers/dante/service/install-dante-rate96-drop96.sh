#!/bin/bash
# The prime drop at 96 kHz raised from 48 to 96 (RATE96_PLAN.md, after the acceptance
# of 2026-11-01): 958 -> 911 at every Mac open at 96, 0.5 ms lower. Two files: the
# start wrapper, whose PRIME_DROP limit becomes one block per rate (0 to 48 for a plain
# or 48 kHz key, 0 to 96 for a 96 kHz one), and transport.conf with PRIME_DROP_96000=96.
# The 48 and 44.1 command lines are unchanged (test-dante-start.sh transport checks it
# on the staged files). Run with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate96-drop96.sh            install the two files pinned below
#   sudo ./install-dante-rate96-drop96.sh rollback   put both back
#
# Keeps the old files as *.rate96drop96-previous in /usr/local/libexec/usb16x16-dante/.
# The owner reads both only when it starts, so this restarts usb16x16-dante (a short
# outage, at whatever rate it runs). Its rollback comes before install-dante-rate96-drop.sh's.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
keep=/usr/local/libexec/usb16x16-dante
unit=usb16x16-dante.service
# name|source|installed path|mode|new hash|old hash
files=(
  "usb16x16-dante-start|$script_dir/usb16x16-dante-start-transport|$keep/usb16x16-dante-start|755|df6a1b0bd22679f8e26050dd4ea9759c18bf598bdac3c771eafcc5f7f1c6b495|93d1b082d71ecb37d5e435a6319e8a4bb5b6ad3c4331a24eafb80bf57629180b"
  "transport.conf|$script_dir/transport-rate96-drop96.conf|/etc/usb16x16/dante/transport.conf|644|5887284a2ae469a57274763817bf42f46b920712a75477929db0f795c170c302|6498b9f49134fdf08cbea66c68ec060a6dce9ef9a54e506cccb73c6dfa29356a"
)
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
field() { echo "$1" | cut -d'|' -f"$2"; }

restart() {
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl restart "$unit"
  sleep 12
  echo "$unit is $(systemctl is-active "$unit");" \
       "$(for f in "${files[@]}"; do printf '%s %s ' "$(field "$f" 1)" "$(sha256_of "$(field "$f" 3)" | cut -c1-8)"; done)"
}

if [ "$(systemctl is-active usb16x16-dante-candidate.service 2>/dev/null)" = active ]; then
  echo "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop)" >&2
  exit 5
fi
case "$(systemctl is-active usb16x16-dante-rate.service 2>/dev/null)" in
  active|activating) echo "a rate change is in progress (usb16x16-dante-rate); try again when it has finished" >&2; exit 6 ;;
esac

if [ "${1:-}" = rollback ]; then
  for f in "${files[@]}"; do
    kept=$keep/$(field "$f" 1).rate96drop96-previous
    [ -f "$kept" ] || { echo "no previous file at $kept" >&2; exit 3; }
    [ "$(sha256_of "$kept")" = "$(field "$f" 6)" ] || { echo "$kept is not $(field "$f" 6 | cut -c1-8); refusing" >&2; exit 4; }
  done
  for f in "${files[@]}"; do
    install -o root -g root -m "$(field "$f" 4)" "$keep/$(field "$f" 1).rate96drop96-previous" "$(field "$f" 3).new"
  done
  for f in "${files[@]}"; do mv -f "$(field "$f" 3).new" "$(field "$f" 3)"; done
  echo "put back the two files"
  restart
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [rollback]" >&2; exit 2; }

for f in "${files[@]}"; do
  src=$(field "$f" 2)
  [ -r "$src" ] || { echo "missing source: $src" >&2; exit 3; }
  [ "$(sha256_of "$src")" = "$(field "$f" 5)" ] || { echo "hash mismatch: $src" >&2; exit 4; }
done
installed_new=0
for f in "${files[@]}"; do
  [ "$(sha256_of "$(field "$f" 3)")" = "$(field "$f" 5)" ] && installed_new=$((installed_new + 1))
done
if [ "$installed_new" -eq "${#files[@]}" ]; then
  echo "already installed"
  exit 0
fi
for f in "${files[@]}"; do
  now=$(sha256_of "$(field "$f" 3)")
  [ "$now" = "$(field "$f" 6)" ] || { echo "the installed $(field "$f" 1) is ${now:0:8}, not the $(field "$f" 6 | cut -c1-8) this replaces; refusing" >&2; exit 4; }
done

for f in "${files[@]}"; do
  install -o root -g root -m "$(field "$f" 4)" "$(field "$f" 3)" "$keep/$(field "$f" 1).rate96drop96-previous"
  install -o root -g root -m "$(field "$f" 4)" "$(field "$f" 2)" "$(field "$f" 3).new"
done
for f in "${files[@]}"; do mv -f "$(field "$f" 3).new" "$(field "$f" 3)"; done
echo "installed the two files; kept the old ones as $keep/*.rate96drop96-previous"
restart
