#!/bin/bash
# Put SAMPLE_RATE_DESIGN.md step 2 into the Dante service: the endpoint
# publishes its sample rate (48 kHz, the only one offered) to Dante Controller
# and netaudio, answers their rate and encoding reads, and refuses a set to any
# other rate. Two files and nothing else; the owner, the units, owner.conf,
# transport.conf, the start check and Statime are left as they are. Run with
# sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate-status.sh            install the two files pinned below
#   sudo ./install-dante-rate-status.sh rollback   put back the two it replaced
#
#   /usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so
#        0ee61f2f -> d3a6b40a  (patches 0001-0004; build-patched.sh
#                               xrun-option-retry1-confirm-rate 0001 0002 0003 0004)
#   /etc/usb16x16/dante/asound-inferno-owner.conf
#        a91f5766 -> 7beabf1a  (asound-inferno-owner-rate48.conf: the installed
#                               config plus SUPPORTED_SAMPLE_RATES 48000,
#                               BOARD_FLAGS_17 18, DEVICE_ID 88a29e8b01e40000 and
#                               STATE_ID 5553423136783136)
#
# The device ID changes (to eth0's MAC plus process 0000, which netaudio can
# read); the name does not. STATE_ID keeps the saved subscriptions in the old
# ID's directory, so a rollback finds them as they were left. The running
# endpoint is NOT restarted: both files are read when it starts.
# `sudo systemctl restart usb16x16-dante` puts them in service (the start
# check judges that start), `sudo systemctl restart usb-16x16.service` for a
# fresh anchor. The old files are kept beside the start wrapper as *.previous.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
libexec=/usr/local/libexec/usb16x16-dante
unit=usb16x16-dante.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
# source | new hash | installed path | mode | hash it replaces | where the old one is kept
files="$script_dir/../plugins/xrun-option-retry1-confirm-rate/libasound_module_pcm_inferno.so|d3a6b40a162e5b3ce9f6abae36cc371a5ed0ede73133e844b1f34bcd0148a355|/usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so|644|0ee61f2ff798abf772a0026b7a37e06da7a5cb80d454559cc2e0355fb1001330|$libexec/libasound_module_pcm_inferno.so.previous
$script_dir/../config/asound-inferno-owner-rate48.conf|7beabf1af983e82e73ba8e0ed4f6a491ec3d4a0bdf313f846ef8cd59a4291b22|/etc/usb16x16/dante/asound-inferno-owner.conf|644|a91f5766ea1bf23bd5c935ed5bbe5b8fe35d7078362a73cef16d2ca57c9a2332|$libexec/asound-inferno-owner.conf.rate-previous"

report() {
  echo "$unit is $(systemctl is-active "$unit" || true), not restarted"
  echo "installed now: plugin $(sha256_of /usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so | cut -c1-8), config $(sha256_of /etc/usb16x16/dante/asound-inferno-owner.conf | cut -c1-8)"
}

if [ "${1:-}" = rollback ]; then
  echo "$files" | while IFS='|' read -r source new installed mode old previous; do
    [ -f "$previous" ] || { echo "no previous copy at $previous" >&2; exit 3; }
    [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not $(echo "$old" | cut -c1-8); refusing" >&2; exit 4; }
    install -o root -g root -m "$mode" "$previous" "$installed.new"
    mv -f "$installed.new" "$installed"
    echo "put back $installed ($(sha256_of "$installed" | cut -c1-8))"
  done
  report
  exit 0
fi

# Everything is checked before anything is written.
echo "$files" | while IFS='|' read -r source new installed mode old previous; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
  current=$(sha256_of "$installed")
  [ "$current" = "$new" ] || [ "$current" = "$old" ] ||
    { echo "$installed is $(echo "$current" | cut -c1-8), neither the $(echo "$old" | cut -c1-8) this replaces nor the new one; refusing" >&2; exit 4; }
done

echo "$files" | while IFS='|' read -r source new installed mode old previous; do
  if [ "$(sha256_of "$installed")" = "$old" ]; then
    install -o root -g root -m "$mode" "$installed" "$previous"
  fi
  install -o root -g root -m "$mode" "$source" "$installed.new"
  mv -f "$installed.new" "$installed"
  echo "installed $installed ($(sha256_of "$installed" | cut -c1-8))"
done
report
