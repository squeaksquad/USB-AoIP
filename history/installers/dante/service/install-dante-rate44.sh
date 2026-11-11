#!/bin/bash
# Offer 44.1 kHz beside 48 kHz (SAMPLE_RATE_DESIGN.md step 7 for one more
# rate). Two files, nothing else: the Inferno config gains 44100 in
# SUPPORTED_SAMPLE_RATES, and the start check gains the rate (it judges flows
# against owner.conf's RATE=, which the applier writes). The owner, plugin,
# applier, units, owner.conf, transport.conf and Statime are left as they are.
# Run with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate44.sh            install the two files pinned below
#   sudo ./install-dante-rate44.sh rollback   put both back (only at 48 kHz)
#
# Verifies the new files against their pinned hashes and the installed ones
# against the hashes they replace, keeps the old ones as *.rate44-previous in
# /usr/local/libexec/usb16x16-dante/, and restarts usb16x16-dante so Inferno
# advertises the new list (a short outage and a new latency draw).
#
# Once installed the applier rewrites SAMPLE_RATE in the Inferno config at each
# rate change, so the installed config's hash is 19da7c70 only at 48 kHz. The
# rollback therefore refuses unless the stack is at 48 (owner.conf has no
# RATE=): move the Mac to 48 first.
#
# 2026-10-28: 44.1 passed its battery on the loop on 2026-10-27, and owner
# rate5 2578c73d (installed the same night) removed its start slips.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
config_source=$script_dir/../config/asound-inferno-owner-rate44-48-arbiter.conf
config_new=19da7c702472dee80287369d38190f3aacbbcb8cd801a99549f403c2e0b87547
config_old=0a1688e18c4ffa2c851719fc8230cbe950e3b936afd1fda29040d6118573ffd1
config_installed=/etc/usb16x16/dante/asound-inferno-owner.conf
check_source=$script_dir/usb16x16-dante-startcheck
check_new=fccfdd62bfbd0b2ce20afcebc293550e552d9b5717cdd19593c7f4c1e435059e
check_old=058e9177a4ce4009e474a277f336db64acb12bcc9b4584b4556a99a80646c56f
check_installed=/usr/local/libexec/usb16x16-dante/usb16x16-dante-startcheck
keep=/usr/local/libexec/usb16x16-dante
owner_conf=/etc/usb16x16/dante/owner.conf
unit=usb16x16-dante.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

restart() {
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl restart "$unit"
  sleep 12
  echo "$unit is $(systemctl is-active "$unit"); config $(sha256_of "$config_installed" | cut -c1-8)," \
       "start check $(sha256_of "$check_installed" | cut -c1-8)"
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
  for f in asound-inferno-owner.conf usb16x16-dante-startcheck; do
    [ -f "$keep/$f.rate44-previous" ] || { echo "no previous file at $keep/$f.rate44-previous" >&2; exit 3; }
  done
  [ "$(sha256_of "$keep/asound-inferno-owner.conf.rate44-previous")" = "$config_old" ] || { echo "the kept config is not 0a1688e1; refusing" >&2; exit 4; }
  [ "$(sha256_of "$keep/usb16x16-dante-startcheck.rate44-previous")" = "$check_old" ] || { echo "the kept start check is not 058e9177; refusing" >&2; exit 4; }
  install -o root -g root -m 644 "$keep/asound-inferno-owner.conf.rate44-previous" "$config_installed.new"
  install -o root -g root -m 755 "$keep/usb16x16-dante-startcheck.rate44-previous" "$check_installed.new"
  mv -f "$config_installed.new" "$config_installed"
  mv -f "$check_installed.new" "$check_installed"
  echo "put back config $(sha256_of "$config_installed" | cut -c1-8) and start check $(sha256_of "$check_installed" | cut -c1-8)"
  restart
  exit 0
fi

for pair in "$config_source:$config_new" "$check_source:$check_new"; do
  f=${pair%%:*}; h=${pair##*:}
  [ -r "$f" ] || { echo "missing source: $f" >&2; exit 3; }
  [ "$(sha256_of "$f")" = "$h" ] || { echo "hash mismatch: $f" >&2; exit 4; }
done
config_now=$(sha256_of "$config_installed")
check_now=$(sha256_of "$check_installed")
if [ "$config_now" = "$config_new" ] && [ "$check_now" = "$check_new" ]; then
  echo "already installed"
  exit 0
fi
[ "$config_now" = "$config_old" ] || { echo "the installed config is $(echo "$config_now" | cut -c1-8), not the 0a1688e1 this replaces; refusing" >&2; exit 4; }
[ "$check_now" = "$check_old" ] || { echo "the installed start check is $(echo "$check_now" | cut -c1-8), not the 058e9177 this replaces; refusing" >&2; exit 4; }

install -o root -g root -m 644 "$config_installed" "$keep/asound-inferno-owner.conf.rate44-previous"
install -o root -g root -m 755 "$check_installed" "$keep/usb16x16-dante-startcheck.rate44-previous"
install -o root -g root -m 644 "$config_source" "$config_installed.new"
install -o root -g root -m 755 "$check_source" "$check_installed.new"
mv -f "$config_installed.new" "$config_installed"
mv -f "$check_installed.new" "$check_installed"
echo "installed config $(sha256_of "$config_installed" | cut -c1-8) and start check $(sha256_of "$check_installed" | cut -c1-8);" \
     "kept the old ones as $keep/*.rate44-previous"
restart
