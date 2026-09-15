#!/bin/bash
# Install usb16x16-web.service and the Apply units on the Pi. Run with sudo
# from the staging directory that holds usb16x16-web, usb16x16-web.service,
# usb16x16-apply, usb16x16-apply.service and usb16x16-apply.path.
#
# The web service is read-only: it serves the web UI, reads status and the
# journal, and stores presets under the user's home. It touches no audio
# device, no systemd unit and no kernel module, and it runs unprivileged. Its
# one write outside the preset store is a request file in the Apply spool.
# usb16x16-apply (root, run by the path unit on that file) is the privileged
# half: it switches usb16x16-aes67.service between ACCEPTED profiles with the
# supervisor's own switch-profile, verifies, rolls back, and leaves a receipt.
# Installing either does not restart, reload or otherwise disturb the audio
# stack; enabling the path unit arms Apply, and the web service must be
# restarted to see the spool (its unit gained a ReadWritePaths entry).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
service_source="$script_dir/usb16x16-web"
unit_source="$script_dir/usb16x16-web.service"
apply_source="$script_dir/usb16x16-apply"
apply_unit_source="$script_dir/usb16x16-apply.service"
apply_path_source="$script_dir/usb16x16-apply.path"
service_destination=/usr/local/bin/usb16x16-web
unit_destination=/etc/systemd/system/usb16x16-web.service
apply_destination=/usr/local/bin/usb16x16-apply
apply_unit_destination=/etc/systemd/system/usb16x16-apply.service
apply_path_destination=/etc/systemd/system/usb16x16-apply.path
apply_dir=/home/bdimaio/usb-16x16-work/web-apply
# The bridge's offline DSP runner (work/phase4-bridge/src/dsp_offline.cpp, the
# same source tree as the accepted bridge 406699bd, built on the Pi 2026-09-10
# in ~/usb-16x16-work/dsp-verify/bridge-build). The applier loads every user
# preset through it (--bench 1) before installing it: the bridge's own loader
# is the check, not a reimplementation.
offline_source=/home/bdimaio/usb-16x16-work/dsp-verify/bridge-build/usb16x16-dsp-offline
offline_destination=/usr/local/libexec/usb16x16-dsp-offline
preset_dir=/home/bdimaio/usb-16x16-work/web-presets
static_dir=/home/bdimaio/usb-16x16-work/web-ui
auth_file=/home/bdimaio/usb-16x16-work/web-auth

expected_service_sha256=207ff5cb5e368615c60c9094f9e0945049a7740a931eb37ab290a0869a93158e
expected_unit_sha256=f7c7d48cab8b12b9b7ed9f5a920efc497e9874760cc9434c979c25ee68b59761
expected_apply_sha256=e6e7e844f402a0ad972ea818ffe3b34cf7543dfbfcb1bac851593070ea93e574
expected_apply_unit_sha256=e11f0fc97ffac7b2f2fa4b0db81018320f702c41bf6e843e0a2ec90c5dc28a63
expected_offline_sha256=8469c2e83b617b7c39918ecf7a86f3032cda91de48eb926569cc061c416c6641
expected_apply_path_sha256=6d53b053014a3cb7203de36f9e7472d370ccced6aee2c1d9a6d309b2d35bec61

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

for source in "$service_source" "$unit_source" "$apply_source" "$apply_unit_source" "$apply_path_source"; do
  [ -r "$source" ] || { echo "missing staged file: $source" >&2; exit 3; }
done
[ "$(sha256_of "$service_source")" = "$expected_service_sha256" ] || {
  echo "usb16x16-web source hash mismatch" >&2; exit 4; }
[ "$(sha256_of "$unit_source")" = "$expected_unit_sha256" ] || {
  echo "usb16x16-web.service source hash mismatch" >&2; exit 5; }
[ "$(sha256_of "$apply_source")" = "$expected_apply_sha256" ] || {
  echo "usb16x16-apply source hash mismatch" >&2; exit 7; }
[ "$(sha256_of "$apply_unit_source")" = "$expected_apply_unit_sha256" ] || {
  echo "usb16x16-apply.service source hash mismatch" >&2; exit 8; }
[ "$(sha256_of "$apply_path_source")" = "$expected_apply_path_sha256" ] || {
  echo "usb16x16-apply.path source hash mismatch" >&2; exit 9; }
[ -r "$offline_source" ] || { echo "missing $offline_source (the dsp-verify build)" >&2; exit 10; }
[ "$(sha256_of "$offline_source")" = "$expected_offline_sha256" ] || {
  echo "usb16x16-dsp-offline hash mismatch at $offline_source" >&2; exit 11; }
[ -r "$static_dir/index.html" ] || {
  echo "no web UI staged at $static_dir/index.html" >&2; exit 6; }

install -o root -g root -m 0755 "$service_source" "$service_destination"
install -o root -g root -m 0644 "$unit_source" "$unit_destination"
install -o root -g root -m 0755 "$apply_source" "$apply_destination"
install -o root -g root -m 0644 "$apply_unit_source" "$apply_unit_destination"
install -o root -g root -m 0644 "$apply_path_source" "$apply_path_destination"
install -o root -g root -m 0755 "$offline_source" "$offline_destination"
install -d -o bdimaio -g bdimaio -m 0755 "$preset_dir"
# The web service (bdimaio) writes request.json here; root writes the
# receipts. Nothing else lives in it.
install -d -o bdimaio -g bdimaio -m 0755 "$apply_dir"
install -d -o root -g root -m 0755 "$apply_dir/receipts"
# Uploaded artifacts wait here (written by the web service, consumed by root).
install -d -o bdimaio -g bdimaio -m 0755 "$apply_dir/presets"
# User presets land beside the two packaged ones; the supervisor requires
# this directory root:root:755.
install -d -o root -g root -m 0755 /etc/usb16x16/dsp
systemctl daemon-reload

echo "installed $service_destination, $unit_destination, $apply_destination and the Apply units"
if [ ! -s "$auth_file" ]; then
  echo
  echo "NOTE: no credentials at $auth_file."
  echo "The service authenticates every request and will not start without a user."
  echo "Create one first, as bdimaio, not root:"
  echo "  $service_destination --auth-file $auth_file --add-user NAME"
fi
echo "start / restart the web service: sudo systemctl enable --now usb16x16-web.service"
echo "                                  sudo systemctl restart usb16x16-web.service"
echo "arm Apply:                        sudo systemctl enable --now usb16x16-apply.path"
echo "disarm Apply (web stays):         sudo systemctl disable --now usb16x16-apply.path"
echo "rollback:      sudo systemctl disable --now usb16x16-apply.path usb16x16-web.service &&"
echo "               sudo rm -f $unit_destination $service_destination \\"
echo "                 $apply_path_destination $apply_unit_destination $apply_destination $offline_destination &&"
echo "               sudo systemctl daemon-reload"
