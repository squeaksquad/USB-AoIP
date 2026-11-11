#!/bin/bash
# Offer 96 kHz beside 44.1 and 48 kHz (RATE96_PLAN.md phase 5). Three files,
# nothing else: the Inferno config gains 96000 in SUPPORTED_SAMPLE_RATES; the
# start wrapper learns the depth keys and KEY_<rate> overrides; transport.conf
# gains the _96000 keys (every depth doubled, arm A; no prime drop or capture
# drain at 96). At 48 and 44.1 the owner's command line is unchanged, byte for
# byte (test-dante-start.sh transport checks it on the staged files). The owner,
# plugin, applier, start check, units, owner.conf and Statime are left as they are.
# Run with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate96.sh            install the three files pinned below
#   sudo ./install-dante-rate96.sh rollback   put all three back (only at 48 kHz)
#
# Verifies the new files against their pinned hashes and the installed ones
# against the hashes they replace, keeps the old ones as *.rate96-previous in
# /usr/local/libexec/usb16x16-dante/, and restarts usb16x16-dante so Inferno
# advertises the new list (a short outage and a new latency draw).
#
# The applier rewrites SAMPLE_RATE in the Inferno config at each rate change, so
# the installed config hashes to 8549af7e only at 48 kHz; both directions
# therefore refuse unless the stack is at 48 (owner.conf has no RATE=). This
# rollback comes before install-owner-ratepoll.sh's, which expects the start
# wrapper f4afa51d.
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
  "asound-inferno-owner.conf|$script_dir/../config/asound-inferno-owner-usb-aoip-rate96.conf|/etc/usb16x16/dante/asound-inferno-owner.conf|644|8549af7e890aac7a5e3f2af751e3135394de249602d79c120b6f9416be996a77|54f3f0bae8781987df0957334e3aeb956f15a25b87cd9d37fc41e8285b2821bc"
  "usb16x16-dante-start|$script_dir/usb16x16-dante-start-transport|$keep/usb16x16-dante-start|755|93d1b082d71ecb37d5e435a6319e8a4bb5b6ad3c4331a24eafb80bf57629180b|f4afa51d4fef13baa7fdfe7cc6fa56c12e37c8b5ffe6d6a638a4ab7466dc78eb"
  "transport.conf|$script_dir/transport-rate96.conf|/etc/usb16x16/dante/transport.conf|644|082ce171e67af0ebb1306d014819e772cb3ba8d7200e66723c1516457e8cabf3|2e2c7a2072de32ea55ea7bfb39e8a349c83b0b06cfe691d353db3775ee1df8d7"
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

if [ "${1:-}" = rollback ]; then
  for f in "${files[@]}"; do
    kept=$keep/$(field "$f" 1).rate96-previous
    [ -f "$kept" ] || { echo "no previous file at $kept" >&2; exit 3; }
    [ "$(sha256_of "$kept")" = "$(field "$f" 6)" ] || { echo "$kept is not $(field "$f" 6 | cut -c1-8); refusing" >&2; exit 4; }
  done
  for f in "${files[@]}"; do
    install -o root -g root -m "$(field "$f" 4)" "$keep/$(field "$f" 1).rate96-previous" "$(field "$f" 3).new"
  done
  for f in "${files[@]}"; do mv -f "$(field "$f" 3).new" "$(field "$f" 3)"; done
  echo "put back the three files"
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
  install -o root -g root -m "$(field "$f" 4)" "$(field "$f" 3)" "$keep/$(field "$f" 1).rate96-previous"
  install -o root -g root -m "$(field "$f" 4)" "$(field "$f" 2)" "$(field "$f" 3).new"
done
for f in "${files[@]}"; do mv -f "$(field "$f" 3).new" "$(field "$f" 3)"; done
echo "installed the three files; kept the old ones as $keep/*.rate96-previous"
restart
