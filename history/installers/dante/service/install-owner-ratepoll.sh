#!/bin/bash
# Owner ratepoll (2026-10-30): replace the installed owner abee374a with c84e6a36 and
# transport.conf 31a2a257 with 2e2c7a20 (the same with PRIME_DROP=28 for 24), together.
# The start wrapper f4afa51d, the units, the plugin, Statime, the Inferno config,
# owner.conf, the service user, its state and the sudo rules are left as they are. Run
# with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-owner-ratepoll.sh            install the two files pinned below
#   sudo ./install-owner-ratepoll.sh rollback   put abee374a and 31a2a257 back
#
# Every file is checked against its pinned hash and every installed one against the
# hash it is expected to replace; usb16x16-dante.service is stopped for the swap, the
# old files are kept beside the new ones as *.ratepoll-previous, and the service is
# started again. The rollback comes before install-owner-anchor.sh rollback.
#
# c84e6a36 (source ec8d60bc) is abee374a's source with one constant changed: while the
# loop owns the gadget the steward checks the host's rate every 100 ms instead of every
# second, so a Mac-only rate change stops the loop before it re-primes at the wrong rate.
# With PRIME_DROP=28 it passed the full battery on 2026-10-30 at daw_timeline 528 (532 at
# 24); 32 sits on the prime floor and was rejected.
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
  "$libexec/usb16x16-dante-owner"          "$base/owner/usb16x16-dante-owner-ratepoll"  c84e6a36f41fe439ba729fb2a15fa05e25f72b34c4415cc618e5b5d8048e95c3 abee374a09d182064480cfa3a733defdbaced7f014cb6e95ef7f0b3e6f986b8e
  "/etc/usb16x16/dante/transport.conf"     "$script_dir/transport-ratepoll.conf"        2e2c7a2072de32ea55ea7bfb39e8a349c83b0b06cfe691d353db3775ee1df8d7 31a2a257a5dd5b67ed3954dcf0808e296c2a86a88e411a1b5a3dc13bce87cb6f
)
start_wrapper=f4afa51d4fef13baa7fdfe7cc6fa56c12e37c8b5ffe6d6a638a4ab7466dc78eb
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

# PRIME_DROP is passed by this start wrapper; any other one may not know the key.
current_start=$(sha256_of "$libexec/usb16x16-dante-start")
[ "$current_start" = "$start_wrapper" ] || { echo "$libexec/usb16x16-dante-start is ${current_start:0:8}, not ${start_wrapper:0:8}; refusing" >&2; exit 4; }

if [ "${1:-}" = rollback ]; then
  for ((i = 0; i < ${#files[@]}; i += 4)); do
    installed=${files[i]} old=${files[i+3]}
    [ -f "$installed.ratepoll-previous" ] || { echo "no $installed.ratepoll-previous" >&2; exit 3; }
    [ "$(sha256_of "$installed.ratepoll-previous")" = "$old" ] || { echo "$installed.ratepoll-previous is not ${old:0:8}; refusing" >&2; exit 4; }
  done
  systemctl stop "$unit"
  for ((i = 0; i < ${#files[@]}; i += 4)); do
    installed=${files[i]}
    install -o root -g root -m "$(mode_of "$installed")" "$installed.ratepoll-previous" "$installed.new"
    mv -f "$installed.new" "$installed"
  done
  echo "put back the two previous files"
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
  install -o root -g root -m "$(mode_of "$installed")" "$installed" "$installed.ratepoll-previous"
  install -o root -g root -m "$(mode_of "$installed")" "$source" "$installed.new"
  mv -f "$installed.new" "$installed"
done
echo "installed; previous files kept as *.ratepoll-previous"
restart
