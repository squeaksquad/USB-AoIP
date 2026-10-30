#!/bin/bash
# Rename the service's gadget to the project's name: usb-16x16.service then runs
# setup-usb-aoip (configfs gadget usb-aoip, product USB-AoIP) in place of
# setup-usb-16x16-rates (studio_audio, USB 16x16). Only names change; the rates,
# descriptors, VID/PID and serial are the installed gadget's, so the audio path
# is the same. The protected unit and script are checked and never written, and
# the rates script stays installed for the rollback. Run with sudo from
# ~/usb-16x16-work/gadget-usb-aoip/ (this script, setup-usb-aoip,
# 10-usb-aoip.conf, 10-rates.conf).
#
#   sudo ./install-gadget-usb-aoip.sh            install, restart the gadget as USB-AoIP
#   sudo ./install-gadget-usb-aoip.sh rollback   back to the rates gadget as USB 16x16
#
# Either way the gadget is stopped under its old name and started under its new
# one, so the Mac sees the device leave and a renamed one arrive: Pro Tools,
# Audio MIDI Setup and Dante Switcher select it again once. The Dante endpoint can
# stay up; its USB half closes and rejoins (the ALSA card is UAC2Gadget either
# way). If the device does not come back within a minute, `sudo killall
# coreaudiod` on the Mac (seen once, 2026-10-17).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
unit=usb-16x16.service
dropin_dir=/etc/systemd/system/$unit.d
udc=/sys/class/udc/1000480000.usb
configfs=/sys/kernel/config/usb_gadget
rates_script=/usr/local/sbin/setup-usb-16x16-rates
rates_dropin=$dropin_dir/10-rates.conf
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
# The protected set; neither file is written.
protected="/etc/systemd/system/$unit|99c87e86acf41676b89ae49267b45abd43b4ead58e871c92be97827e884ffa3d
/usr/local/sbin/setup-usb-16x16|b11fd3589ff1b554cece30fa1ab89f1dbcb2d98ed86db26c2ab0f5becf58b769"
rates_script_hash=d4f0ee7bdf8b6268934ee8577c9d0df910379e9beb77ab03a9c36af27fbff70c
rates_dropin_hash=2310e8f1ee637a4ce096c1b7b2df4998de6777e40f7e9bae1606fbd88dc6025f
# source | pinned hash | destination | mode
files="$script_dir/setup-usb-aoip|65d26567a29fa22c4d61c79c155004c9faaff99012ae492368d39a998995d585|/usr/local/sbin/setup-usb-aoip|755
$script_dir/10-usb-aoip.conf|91449df9cbfd4c24241d25b9e403340aedf406fe5efa319d750b6581ff8b988b|$dropin_dir/10-usb-aoip.conf|644"

echo "$protected" | while IFS='|' read -r path hash; do
  [ "$(sha256_of "$path")" = "$hash" ] || { echo "refusing: $path is not the protected file (${hash:0:8})" >&2; exit 4; }
done
[ "$(sha256_of "$rates_script")" = "$rates_script_hash" ] ||
  { echo "refusing: $rates_script is not the rates gadget (${rates_script_hash:0:8})" >&2; exit 4; }

# Start the gadget and wait for the host: configured at high speed, under the expected names.
start_and_check() {
  local gadget=$1 product=$2 i
  systemctl daemon-reload
  systemctl start "$unit"
  for i in $(seq 1 20); do
    if [ "$(cat $udc/state 2>/dev/null)" = configured ] && [ "$(cat $udc/current_speed 2>/dev/null)" = high-speed ]; then
      break
    fi
    sleep 1
  done
  local fn=$configfs/$gadget/functions/uac2.usb0
  echo "UDC $(cat $udc/state 2>/dev/null || echo absent)/$(cat $udc/current_speed 2>/dev/null || echo absent);" \
    "gadget=$gadget product=$(cat $configfs/$gadget/strings/0x409/product 2>/dev/null || echo absent)" \
    "p_srate=$(cat $fn/p_srate 2>/dev/null) c_srate=$(cat $fn/c_srate 2>/dev/null) req_number=$(cat $fn/req_number 2>/dev/null)"
  [ "$(cat $configfs/$gadget/strings/0x409/product 2>/dev/null)" = "$product" ] ||
    { echo "the gadget is not $gadget / $product" >&2; exit 5; }
  [ "$(cat $fn/p_srate)" = 48000,44100,88200,96000 ] && [ "$(cat $fn/c_srate)" = 48000,44100,88200,96000 ] ||
    { echo "the gadget does not offer the four rates" >&2; exit 5; }
  [ "$(cat $udc/state 2>/dev/null)" = configured ] || { echo "the host has not configured the gadget after 20 s" >&2; exit 6; }
  echo "usb16x16-dante is $(systemctl is-active usb16x16-dante.service || true)"
}

if [ "${1:-}" = rollback ]; then
  source=$script_dir/10-rates.conf
  [ "$(sha256_of "$source")" = "$rates_dropin_hash" ] || { echo "hash mismatch: $source" >&2; exit 4; }
  # Stopped with the unit as it is now, so its own script tears down usb-aoip.
  systemctl stop "$unit"
  echo "$files" | while IFS='|' read -r src hash destination mode; do rm -f "$destination"; echo "removed $destination"; done
  install -o root -g root -m 644 "$source" "$rates_dropin.new"
  mv -f "$rates_dropin.new" "$rates_dropin"
  echo "installed $rates_dropin ($(sha256_of "$rates_dropin" | cut -c1-8))"
  start_and_check studio_audio 'USB 16x16'
  echo "rolled back: $unit runs the rates gadget as USB 16x16"
  exit 0
fi

[ "$(sha256_of "$rates_dropin")" = "$rates_dropin_hash" ] ||
  { echo "refusing: $rates_dropin is not the rates drop-in (${rates_dropin_hash:0:8})" >&2; exit 4; }
echo "$files" | while IFS='|' read -r source hash destination mode; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$hash" ] || { echo "hash mismatch: $source" >&2; exit 4; }
done
# Stopped with the rates drop-in still in place, so its script tears down studio_audio.
systemctl stop "$unit"
echo "$files" | while IFS='|' read -r source hash destination mode; do
  install -o root -g root -m "$mode" "$source" "$destination.new"
  mv -f "$destination.new" "$destination"
  echo "installed $destination ($(sha256_of "$destination" | cut -c1-8))"
done
rm -f "$rates_dropin"
echo "removed $rates_dropin (kept in $script_dir for the rollback)"
start_and_check usb-aoip USB-AoIP
echo "installed: $unit runs the gadget as USB-AoIP; rollback with: sudo $0 rollback"
