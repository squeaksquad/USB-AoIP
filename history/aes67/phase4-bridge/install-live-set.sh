#!/bin/bash
# Install or roll back the live-coefficient set on the Pi: the bridge
# 7e8f1064 (LIVE_COEFFICIENTS_DESIGN.md steps 2-3) and the supervisor that
# pins it and passes DSP_LIVE. Hash-guarded both ways, refuses while the AES67
# service is active, changes nothing else: the unit, the conf, sudoers and the
# USB baseline are untouched. Run as root from the staging directory.
#
#   sudo ./install-live-set.sh install     bridge + supervisor from this directory
#   sudo ./install-live-set.sh rollback    the accepted 947e8b4d / 23e40f8c from rollback/
#
# The web-control half (usb16x16-web 1.x, usb16x16-apply 1.2.0) is installed by
# its own hash-guarded installer, work/web-control/install-web-control.sh, and
# rolled back the same way from rollback/web-control/.
set -euo pipefail
cd "$(dirname "$0")"
mode=${1:-}
[ "$mode" = install ] || [ "$mode" = rollback ] || { echo "usage: $0 install|rollback" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run as root with sudo" >&2; exit 2; }
if [ "$(systemctl is-active usb16x16-aes67.service)" = active ]; then
  echo "usb16x16-aes67.service is active; stop it first" >&2
  exit 8
fi
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
bridge_destination=/usr/local/libexec/usb16x16-rt-bridge
supervisor_destination=/usr/local/sbin/usb16x16-aes67-supervisor
live_bridge=7e8f106404e38b0ffb814595102c9b3f89bc215ff91c5d147ba63593363f799f
live_supervisor=8b42e4ecf449ef6f41ed7995e4fdd1202f34a6b47f44b3cd96310abdbc14292f
accepted_bridge=947e8b4d6842239b5cc33eeedb1a083d292995cdcdd558bb84017d9af45d5d50
accepted_supervisor=23e40f8c604152caf8de7d97065731cc3c03f8896d535118b5d81b0d203e15ae
if [ "$mode" = install ]; then
  bridge_source=usb16x16-rt-bridge; supervisor_source=usb16x16-aes67-supervisor
  want_bridge=$live_bridge; want_supervisor=$live_supervisor
else
  bridge_source=rollback/usb16x16-rt-bridge; supervisor_source=rollback/usb16x16-aes67-supervisor
  want_bridge=$accepted_bridge; want_supervisor=$accepted_supervisor
fi
for pair in "$bridge_source:$want_bridge" "$supervisor_source:$want_supervisor"; do
  path=${pair%%:*}; want=${pair##*:}
  [ -r "$path" ] || { echo "missing $path" >&2; exit 10; }
  [ "$(sha256_of "$path")" = "$want" ] || { echo "hash mismatch: $path is $(sha256_of "$path" | cut -c1-8), expected ${want:0:8}" >&2; exit 11; }
done
echo "before: bridge $(sha256_of $bridge_destination | cut -c1-8) supervisor $(sha256_of $supervisor_destination | cut -c1-8)"
install -o root -g root -m 755 "$bridge_source" "$bridge_destination"
install -o root -g root -m 755 "$supervisor_source" "$supervisor_destination"
echo "after:  bridge $(sha256_of $bridge_destination | cut -c1-8) supervisor $(sha256_of $supervisor_destination | cut -c1-8)"
"$supervisor_destination" profiles > /dev/null || { echo "the installed supervisor cannot parse the live configuration" >&2; exit 12; }
echo "$mode done; the service is not started. Next: sudo systemctl start usb16x16-aes67"
