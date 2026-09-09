#!/bin/bash
# Install usb16x16-web.service on the Pi. Run once with sudo from the staging
# directory that holds usb16x16-web and usb16x16-web.service.
#
# The service is read-only: it serves the web UI, reads status and the journal,
# and stores presets under the user's home. It touches no audio device, no
# systemd unit and no kernel module, and it runs unprivileged. Installing it
# does not restart, reload or otherwise disturb the audio stack.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
service_source="$script_dir/usb16x16-web"
unit_source="$script_dir/usb16x16-web.service"
service_destination=/usr/local/bin/usb16x16-web
unit_destination=/etc/systemd/system/usb16x16-web.service
preset_dir=/home/bdimaio/usb-16x16-work/web-presets
static_dir=/home/bdimaio/usb-16x16-work/web-ui
auth_file=/home/bdimaio/usb-16x16-work/web-auth

expected_service_sha256=c8872ef948333305a79575b8adc6b66b31a8ff7c51c63552a7bbc30ba95d6f54
expected_unit_sha256=97290615b1db2ee453b7f8d37a1a492529559d5ce1fbf89b215a2c171141914c

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

for source in "$service_source" "$unit_source"; do
  [ -r "$source" ] || { echo "missing staged file: $source" >&2; exit 3; }
done
[ "$(sha256_of "$service_source")" = "$expected_service_sha256" ] || {
  echo "usb16x16-web source hash mismatch" >&2; exit 4; }
[ "$(sha256_of "$unit_source")" = "$expected_unit_sha256" ] || {
  echo "usb16x16-web.service source hash mismatch" >&2; exit 5; }
[ -r "$static_dir/index.html" ] || {
  echo "no web UI staged at $static_dir/index.html" >&2; exit 6; }

install -o root -g root -m 0755 "$service_source" "$service_destination"
install -o root -g root -m 0644 "$unit_source" "$unit_destination"
install -d -o bdimaio -g bdimaio -m 0755 "$preset_dir"
systemctl daemon-reload

echo "installed $service_destination and $unit_destination"
if [ ! -s "$auth_file" ]; then
  echo
  echo "NOTE: no credentials at $auth_file."
  echo "The service authenticates every request and will not start without a user."
  echo "Create one first, as bdimaio, not root:"
  echo "  $service_destination --auth-file $auth_file --add-user NAME"
fi
echo "start it with: sudo systemctl enable --now usb16x16-web.service"
echo "rollback:      sudo systemctl disable --now usb16x16-web.service &&"
echo "               sudo rm -f $unit_destination $service_destination &&"
echo "               sudo systemctl daemon-reload"
