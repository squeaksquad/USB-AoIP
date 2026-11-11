#!/bin/bash
# Offer 88.2 kHz beside 44.1, 48 and 96 kHz (RATE882_PLAN.md phase 5). Two files,
# nothing else: the Inferno config gains 88200 in SUPPORTED_SAMPLE_RATES, and
# transport.conf gains the _88200 keys (96's arm A depths, prime drop 72 with the
# capture drain: 888-889 at every open at 88.2 on the 2026-11-01 battery). At 48,
# 44.1 and 96 the owner's command line is unchanged, byte for byte
# (test-dante-start.sh transport checks it on the staged files). The start wrapper
# df6a1b0b already takes the 88.2 keys. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate882.sh            install the two files pinned below
#   sudo ./install-dante-rate882.sh rollback   put both back (only at 48 kHz)
#
# Verifies the new files against their pinned hashes and the installed ones
# against the hashes they replace, keeps the old ones as *.rate882-previous in
# /usr/local/libexec/usb16x16-dante/, and restarts usb16x16-dante so Inferno
# advertises the new list (a short outage and a new latency draw).
#
# The applier rewrites SAMPLE_RATE in the Inferno config at each rate change, so
# the installed config hashes to 8549af7e (85a5256f after) only at 48 kHz; both
# directions therefore refuse unless the stack is at 48 (owner.conf has no RATE=).
# This rollback comes before install-dante-rate96-drop96.sh's.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
keep=/usr/local/libexec/usb16x16-dante
owner_conf=/etc/usb16x16/dante/owner.conf
unit=usb16x16-dante.service
# name|source|installed path|mode|new hash|old hash
files=(
  "asound-inferno-owner.conf|$script_dir/../config/asound-inferno-owner-usb-aoip-rate882.conf|/etc/usb16x16/dante/asound-inferno-owner.conf|644|85a5256f833342fc466a942bd792660d637507e5ad7b56df07ee347d861f61fe|8549af7e890aac7a5e3f2af751e3135394de249602d79c120b6f9416be996a77"
  "transport.conf|$script_dir/transport-rate882.conf|/etc/usb16x16/dante/transport.conf|644|add1bc21b3532cbd618fcac76a38aef554a0b66a3fcd69d42f628498fa48b192|5887284a2ae469a57274763817bf42f46b920712a75477929db0f795c170c302"
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
if grep -q '^RATE=' "$owner_conf"; then
  echo "owner.conf has $(grep '^RATE=' "$owner_conf"); this runs only at 48 kHz: move the Mac to 48 first" >&2
  exit 6
fi
case "$(systemctl is-active usb16x16-dante-rate.service 2>/dev/null)" in
  active|activating) echo "a rate change is in progress (usb16x16-dante-rate); try again when it has finished" >&2; exit 6 ;;
esac

if [ "${1:-}" = rollback ]; then
  for f in "${files[@]}"; do
    kept=$keep/$(field "$f" 1).rate882-previous
    [ -f "$kept" ] || { echo "no previous file at $kept" >&2; exit 3; }
    [ "$(sha256_of "$kept")" = "$(field "$f" 6)" ] || { echo "$kept is not $(field "$f" 6 | cut -c1-8); refusing" >&2; exit 4; }
  done
  for f in "${files[@]}"; do
    install -o root -g root -m "$(field "$f" 4)" "$keep/$(field "$f" 1).rate882-previous" "$(field "$f" 3).new"
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
  install -o root -g root -m "$(field "$f" 4)" "$(field "$f" 3)" "$keep/$(field "$f" 1).rate882-previous"
  install -o root -g root -m "$(field "$f" 4)" "$(field "$f" 2)" "$(field "$f" 3).new"
done
for f in "${files[@]}"; do mv -f "$(field "$f" 3).new" "$(field "$f" 3)"; done
echo "installed the two files; kept the old ones as $keep/*.rate882-previous"
restart
