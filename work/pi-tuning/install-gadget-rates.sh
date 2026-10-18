#!/bin/bash
# Install or remove the multi-rate gadget as the service's gadget: usb-16x16.service
# then offers 44.1, 48, 88.2 and 96 kHz instead of 48 kHz alone. The protected unit
# (/etc/systemd/system/usb-16x16.service) and script (/usr/local/sbin/setup-usb-16x16,
# b11fd358) are checked and left untouched; a drop-in points the unit at
# setup-usb-16x16-rates. Run with sudo from ~/usb-16x16-work/gadget-rates/.
#
#   sudo ./install-gadget-rates.sh            install the pair pinned below and restart the gadget
#   sudo ./install-gadget-rates.sh rollback   remove them and restart the protected gadget
#
# Either way the gadget is restarted, so the Mac re-enumerates the USB 16x16. The Dante
# endpoint can stay up: its USB half closes and rejoins, as on any gadget restart. If
# the device does not come back in Audio MIDI Setup within a minute, `sudo killall
# coreaudiod` on the Mac (seen once, 2026-10-17). Measured before this installer: the
# multi-rate gadget's battery, hour and five anchors (PROJECT_HANDOFF.md, 2026-10-17/18).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
unit=usb-16x16.service
dropin_dir=/etc/systemd/system/$unit.d
gadget_fn=/sys/kernel/config/usb_gadget/studio_audio/functions/uac2.usb0
udc=/sys/class/udc/1000480000.usb
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
# The protected set this install sits on; neither file is written.
protected="/etc/systemd/system/$unit|99c87e86acf41676b89ae49267b45abd43b4ead58e871c92be97827e884ffa3d
/usr/local/sbin/setup-usb-16x16|b11fd3589ff1b554cece30fa1ab89f1dbcb2d98ed86db26c2ab0f5becf58b769"
# source | pinned hash | destination | mode
files="$script_dir/setup-usb-16x16-rates|d4f0ee7bdf8b6268934ee8577c9d0df910379e9beb77ab03a9c36af27fbff70c|/usr/local/sbin/setup-usb-16x16-rates|755
$script_dir/10-rates.conf|2310e8f1ee637a4ce096c1b7b2df4998de6777e40f7e9bae1606fbd88dc6025f|$dropin_dir/10-rates.conf|644"

echo "$protected" | while IFS='|' read -r path hash; do
  [ "$(sha256_of "$path")" = "$hash" ] || { echo "refusing: $path is not the protected file (${hash:0:8})" >&2; exit 4; }
done

# Restart the gadget and wait for the host: configured at high speed with the expected rates.
restart_and_check() {
  local want=$1 i
  systemctl daemon-reload
  systemctl restart "$unit"
  for i in $(seq 1 20); do
    if [ "$(cat $udc/state 2>/dev/null)" = configured ] && [ "$(cat $udc/current_speed 2>/dev/null)" = high-speed ]; then
      break
    fi
    sleep 1
  done
  echo "UDC $(cat $udc/state 2>/dev/null || echo absent)/$(cat $udc/current_speed 2>/dev/null || echo absent);" \
    "p_srate=$(cat $gadget_fn/p_srate) c_srate=$(cat $gadget_fn/c_srate) req_number=$(cat $gadget_fn/req_number)"
  [ "$(cat $gadget_fn/p_srate)" = "$want" ] && [ "$(cat $gadget_fn/c_srate)" = "$want" ] ||
    { echo "the gadget does not offer $want" >&2; exit 5; }
  [ "$(cat $udc/state 2>/dev/null)" = configured ] || { echo "the host has not configured the gadget after 20 s" >&2; exit 6; }
  echo "usb16x16-dante is $(systemctl is-active usb16x16-dante.service || true)"
}

if [ "${1:-}" = rollback ]; then
  echo "$files" | while IFS='|' read -r source hash destination mode; do rm -f "$destination"; echo "removed $destination"; done
  rmdir "$dropin_dir" 2>/dev/null || true
  restart_and_check 48000
  echo "rolled back: $unit runs the protected gadget (48 kHz only)"
  exit 0
fi

echo "$files" | while IFS='|' read -r source hash destination mode; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$hash" ] || { echo "hash mismatch: $source" >&2; exit 4; }
done
mkdir -p "$dropin_dir"
echo "$files" | while IFS='|' read -r source hash destination mode; do
  install -o root -g root -m "$mode" "$source" "$destination.new"
  mv -f "$destination.new" "$destination"
  echo "installed $destination ($(sha256_of "$destination" | cut -c1-8))"
done
# A hand-run experiment gadget's marker would make its status read "active".
rm -f /run/usb16x16-gadget-multirate
restart_and_check 48000,44100,88200,96000
echo "installed: $unit runs the multi-rate gadget; rollback with: sudo $0 rollback"
