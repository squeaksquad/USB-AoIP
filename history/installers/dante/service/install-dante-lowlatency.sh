#!/bin/bash
# Put the two latency gains of 2026-10-12 into the Dante service, together:
# both Inferno latency knobs at 1 ms, and the owner's return queue at 96
# frames. Three files and nothing else; the owner binary, the plugin, the
# units, owner.conf, the start check and Statime are left as they are. Run
# with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-lowlatency.sh            install the three files pinned below
#   sudo ./install-dante-lowlatency.sh rollback   put back the two it replaced, remove the third
#
#   /etc/usb16x16/dante/asound-inferno-owner.conf    924cfa99 -> a91f5766 (RX and TX latency 2 ms -> 1 ms)
#   /usr/local/libexec/usb16x16-dante/usb16x16-dante-start
#                                                    1f83825b -> 882f48ac (also reads transport.conf)
#   /etc/usb16x16/dante/transport.conf               new: RX_QUEUE=96
#
# The running endpoint is NOT restarted: all three are read when it starts.
# To put them in service, `sudo systemctl restart usb16x16-dante` (the start
# check then judges that start as usual) and `sudo systemctl restart
# usb-16x16.service` for a fresh anchor. The old files are kept beside the
# wrapper as *.previous. Either both gains or neither: an installed state
# that is half of this was not measured as a service.
#
# The Inferno config installed is byte for byte the measured one, so its
# header still calls itself an experiment; the pin is what matters.
# After this, install-dante-dsp.sh and install-dante-service.sh no longer
# report "already installed" (they pin what this replaces), and
# install-dante-latency.sh reports the config as already installed.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
libexec=/usr/local/libexec/usb16x16-dante
unit=usb16x16-dante.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
# source | new hash | installed path | mode | hash it replaces (- for a new file) | where the old one is kept
files="$script_dir/../config/asound-inferno-owner-both1ms.conf|a91f5766ea1bf23bd5c935ed5bbe5b8fe35d7078362a73cef16d2ca57c9a2332|/etc/usb16x16/dante/asound-inferno-owner.conf|644|924cfa99f69c6ab1a34488417cb9f92d30b61da4dc29fb37ca785f9d4d1feaae|$libexec/asound-inferno-owner.conf.previous
$script_dir/usb16x16-dante-start-transport|882f48acd4d795eb2243e08785198204d86c9cf232ab3141e92b7dac4835f66b|$libexec/usb16x16-dante-start|755|1f83825b9a1b98671e10f75f5a80a1d0f4676e5e5792997a5b2e1d7d2927e4e7|$libexec/usb16x16-dante-start.previous
$script_dir/transport.conf|821bc306274ff374a739edc9e3e488bf164bdc478b0ae3e98735efa6969ef5f0|/etc/usb16x16/dante/transport.conf|644|-|-"

report() {
  echo "$unit is $(systemctl is-active "$unit" || true), not restarted"
  echo "installed now: config $(sha256_of /etc/usb16x16/dante/asound-inferno-owner.conf | cut -c1-8), wrapper $(sha256_of "$libexec/usb16x16-dante-start" | cut -c1-8), transport.conf $([ -f /etc/usb16x16/dante/transport.conf ] && sha256_of /etc/usb16x16/dante/transport.conf | cut -c1-8 || echo absent)"
  echo "the next start would run:"
  "$libexec/usb16x16-dante-start" --print | tr '\n' ' '; echo
}

if [ "${1:-}" = rollback ]; then
  echo "$files" | while IFS='|' read -r source new installed mode old previous; do
    if [ "$old" = - ]; then rm -f "$installed"; echo "removed $installed"; continue; fi
    [ -f "$previous" ] || { echo "no previous copy at $previous" >&2; exit 3; }
    [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not $(echo "$old" | cut -c1-8); refusing" >&2; exit 4; }
    install -o root -g root -m "$mode" "$previous" "$installed"
    echo "put back $installed ($(sha256_of "$installed" | cut -c1-8))"
  done
  report
  exit 0
fi

# Everything is checked before anything is written.
echo "$files" | while IFS='|' read -r source new installed mode old previous; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
  [ "$old" = - ] && continue
  current=$(sha256_of "$installed")
  [ "$current" = "$new" ] || [ "$current" = "$old" ] ||
    { echo "$installed is $(echo "$current" | cut -c1-8), neither the $(echo "$old" | cut -c1-8) this replaces nor the new one; refusing" >&2; exit 4; }
done
bash -n "$script_dir/usb16x16-dante-start-transport"
USB16X16_DANTE_TRANSPORT="$script_dir/transport.conf" "$script_dir/usb16x16-dante-start-transport" --print >/dev/null ||
  { echo "the new wrapper refuses the installed owner.conf with this transport.conf; nothing changed" >&2; exit 4; }

echo "$files" | while IFS='|' read -r source new installed mode old previous; do
  if [ "$old" != - ] && [ "$(sha256_of "$installed")" = "$old" ]; then
    install -o root -g root -m "$mode" "$installed" "$previous"
  fi
  install -o root -g root -m "$mode" "$source" "$installed.new"
  mv -f "$installed.new" "$installed"
  echo "installed $installed ($(sha256_of "$installed" | cut -c1-8))"
done
report
