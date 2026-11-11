#!/bin/bash
# Replace the installed Inferno ALSA config with the one that sets both
# latency knobs to 1 ms, and nothing else: the owner, the wrapper, owner.conf,
# the plugin, the units and Statime are left as they are. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-latency.sh            install the config pinned below
#   sudo ./install-dante-latency.sh rollback   put the previous config back
#
# Verifies the new config against its pinned hash and the installed one
# against the hash it is expected to replace, and keeps the old config as
# /usr/local/libexec/usb16x16-dante/asound-inferno-owner.conf.previous. The
# running endpoint is NOT restarted: Inferno reads the config when the PCM is
# opened, so the change takes effect at the next start of usb16x16-dante
# (`sudo systemctl restart usb16x16-dante`: a short outage and a new latency
# draw; follow it with a gadget restart for a fresh anchor).
#
# 2026-10-12: RX_LATENCY_NS and TX_LATENCY_NS from 2 ms to 1 ms each
# (RESULTS.md, "Inferno latency at 1 ms"). The file installed is byte for
# byte the one the candidate runs, the battery and the hour were measured on,
# so its header still calls itself an experiment; the pin is what matters.
# The two knobs must stay equal: with only the advertised one at 1 ms every
# probe had holes.
#
# After this, install-dante-service.sh no longer reports "already installed"
# (it pins the config this replaces).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
source=$script_dir/../config/asound-inferno-owner-both1ms.conf
new=a91f5766ea1bf23bd5c935ed5bbe5b8fe35d7078362a73cef16d2ca57c9a2332
old=924cfa99f69c6ab1a34488417cb9f92d30b61da4dc29fb37ca785f9d4d1feaae
unit=usb16x16-dante.service
installed=/etc/usb16x16/dante/asound-inferno-owner.conf
previous=/usr/local/libexec/usb16x16-dante/asound-inferno-owner.conf.previous
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

report() {
  echo "$unit is $(systemctl is-active "$unit" || true), not restarted; config $(sha256_of "$installed" | cut -c1-8)"
  grep -E '^\s*(RX|TX)_LATENCY_NS' "$installed"
}

if [ "${1:-}" = rollback ]; then
  [ -f "$previous" ] || { echo "no previous config at $previous" >&2; exit 3; }
  [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not 924cfa99; refusing" >&2; exit 4; }
  install -o root -g root -m 644 "$previous" "$installed"
  echo "put back $(sha256_of "$installed" | cut -c1-8)"
  report
  exit 0
fi

[ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
[ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
current=$(sha256_of "$installed")
if [ "$current" = "$new" ]; then
  echo "already installed: $(echo "$new" | cut -c1-8)"
  exit 0
fi
[ "$current" = "$old" ] || { echo "the installed config is $(echo "$current" | cut -c1-8), not the 924cfa99 this replaces; refusing" >&2; exit 4; }

install -o root -g root -m 644 "$installed" "$previous"
install -o root -g root -m 644 "$source" "$installed.new"
mv -f "$installed.new" "$installed"
echo "installed $(sha256_of "$installed" | cut -c1-8), kept $(sha256_of "$previous" | cut -c1-8) as $previous"
report
