#!/bin/bash
# Name the Dante device after the project: Inferno advertises USB-AoIP in place
# of USB-16x16-Inferno, and the four Dante units describe themselves as USB-AoIP
# (drop-ins, so the unit files the earlier installers pin are never written).
# The owner, plugin, transport.conf, owner.conf, unit names and DEVICE_ID /
# STATE_ID are left as they are, so the audio path and the Pi's own saved
# subscriptions are the installed ones. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-name.sh            install, restart the endpoint as USB-AoIP
#   sudo ./install-dante-name.sh rollback   back to USB-16x16-Inferno (only at 48 kHz)
#
# Receivers subscribe by device name, so after either direction the Pulse's
# Input 17-32 point at a name that no longer exists until they are made again
# (from the Mac):
#   netaudio subscription add --tx USB-AoIP --rx FF-PULSE-16-DX --count 16 --offset-rx 16
# (rollback: --tx USB-16x16-Inferno). The loop returns nothing until then.
#
# The applier rewrites SAMPLE_RATE in the Inferno config at each rate change, so
# both directions refuse unless the stack is at 48 (owner.conf has no RATE=).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
config_source=$script_dir/../config/asound-inferno-owner-usb-aoip.conf
config_new=54f3f0bae8781987df0957334e3aeb956f15a25b87cd9d37fc41e8285b2821bc
config_old=19da7c702472dee80287369d38190f3aacbbcb8cd801a99549f403c2e0b87547
config_installed=/etc/usb16x16/dante/asound-inferno-owner.conf
keep=/usr/local/libexec/usb16x16-dante
owner_conf=/etc/usb16x16/dante/owner.conf
unit=usb16x16-dante.service
dropin=10-usb-aoip.conf
# unit suffix : pinned hash of service/10-usb-aoip-<suffix>.conf
dropins="dante:7337e9f1ea03cf71803a9c05ca42f5098050031b0b3be3ebd2ea89fbcf62474d
statime:599fe71eba09d8ef0072fab5039b265af4ba8cc7056f332b547a45b9cb1b6521
dante-startcheck:59c6331779fe8070455d8ac065eac8bd5fa9cf690e6d52c0b043ea1998dedc4a
dante-rate:4fb549a560b6972724c5bddeef33450503a48f5a922901983bb2296e5d9e5d6b"
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

restart() {
  systemctl daemon-reload
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl restart "$unit"
  sleep 12
  echo "$unit ($(systemctl show -p Description --value "$unit")) is $(systemctl is-active "$unit");" \
       "config $(sha256_of "$config_installed" | cut -c1-8), $(grep -m1 -o 'NAME "[^"]*"' "$config_installed")"
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
  [ -f "$keep/asound-inferno-owner.conf.name-previous" ] || { echo "no previous config at $keep/asound-inferno-owner.conf.name-previous" >&2; exit 3; }
  [ "$(sha256_of "$keep/asound-inferno-owner.conf.name-previous")" = "$config_old" ] || { echo "the kept config is not 19da7c70; refusing" >&2; exit 4; }
  install -o root -g root -m 644 "$keep/asound-inferno-owner.conf.name-previous" "$config_installed.new"
  mv -f "$config_installed.new" "$config_installed"
  while IFS=: read -r n _; do
    rm -f "/etc/systemd/system/usb16x16-$n.service.d/$dropin"
    rmdir "/etc/systemd/system/usb16x16-$n.service.d" 2>/dev/null || true
  done <<< "$dropins"
  echo "put back config $(sha256_of "$config_installed" | cut -c1-8) and removed the description drop-ins"
  restart
  exit 0
fi

[ -r "$config_source" ] || { echo "missing source: $config_source" >&2; exit 3; }
[ "$(sha256_of "$config_source")" = "$config_new" ] || { echo "hash mismatch: $config_source" >&2; exit 4; }
while IFS=: read -r n h; do
  f=$script_dir/10-usb-aoip-$n.conf
  [ -r "$f" ] || { echo "missing source: $f" >&2; exit 3; }
  [ "$(sha256_of "$f")" = "$h" ] || { echo "hash mismatch: $f" >&2; exit 4; }
done <<< "$dropins"
config_now=$(sha256_of "$config_installed")
if [ "$config_now" = "$config_new" ]; then
  echo "already installed"
  exit 0
fi
[ "$config_now" = "$config_old" ] || { echo "the installed config is $(echo "$config_now" | cut -c1-8), not the 19da7c70 this replaces; refusing" >&2; exit 4; }

install -o root -g root -m 644 "$config_installed" "$keep/asound-inferno-owner.conf.name-previous"
install -o root -g root -m 644 "$config_source" "$config_installed.new"
mv -f "$config_installed.new" "$config_installed"
while IFS=: read -r n _; do
  install -d -o root -g root -m 755 "/etc/systemd/system/usb16x16-$n.service.d"
  install -o root -g root -m 644 "$script_dir/10-usb-aoip-$n.conf" "/etc/systemd/system/usb16x16-$n.service.d/$dropin"
done <<< "$dropins"
echo "installed config $(sha256_of "$config_installed" | cut -c1-8) and the description drop-ins;" \
     "kept the old config as $keep/asound-inferno-owner.conf.name-previous"
restart
echo "now, from the Mac: netaudio subscription add --tx USB-AoIP --rx FF-PULSE-16-DX --count 16 --offset-rx 16"
