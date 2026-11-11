#!/bin/bash
# Put SAMPLE_RATE_DESIGN.md steps 3 and 4 into the Dante service: the owner
# takes the rate as a parameter and checks the Mac's rate before joining the
# gadget; a set to another offered rate (from Dante Controller or Dante
# Switcher) or a Mac at another rate becomes a request for the arbiter
# (usb16x16-apply --rate-request), which restarts the endpoint at that rate or
# refuses. With 48000 the only rate offered, as here, nothing is ever handed on:
# a set to 48000 is acknowledged and restarts nothing, any other is refused.
# Battery and loaded hour as a candidate: RESULTS.md, 2026-10-17 12:56 UTC.
# Run with sudo from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-rate-arbiter.sh            install the files pinned below
#   sudo ./install-dante-rate-arbiter.sh rollback   put back what it replaced, remove what it added
#
#   /usr/local/libexec/usb16x16-dante/usb16x16-dante-owner
#        62879558 -> c8b484ac  (owner/main.cpp 2b63918c with the bridge core
#                               bbaec39e: --rate, the gadget-rate check,
#                               --rate-request-file, the unity-skip DSP core)
#   /usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so
#        d3a6b40a -> c6b012ae  (patches 0001-0005; build-patched.sh
#                               xrun-option-retry1-confirm-rate-arbiter 0001 0002 0003 0004 0005)
#   /etc/usb16x16/dante/asound-inferno-owner.conf
#        7beabf1a -> 0a1688e1  (asound-inferno-owner-rate48-arbiter.conf: the
#                               installed config plus RATE_REQUEST_FILE)
#   /usr/local/libexec/usb16x16-dante/usb16x16-dante-start
#        882f48ac -> a6c3a197  (usb16x16-dante-start-transport: RATE in owner.conf
#                               is --rate, RATE_REQUESTS in transport.conf is
#                               --rate-request-file)
#   /etc/usb16x16/dante/transport.conf
#        821bc306 -> 1434f79f  (transport-rate-requests.conf: RX_QUEUE=96 as before,
#                               plus RATE_REQUESTS=1)
#   /etc/systemd/system/usb16x16-dante-rate.path      new, f3ec747c, enabled
#   /etc/systemd/system/usb16x16-dante-rate.service   new, a6971bae
#
# The applier that the units run (usb16x16-apply 1.5.0 with the rate kind) and
# the web service that reports the rate are installed by
# ../../web-control/install-web-control.sh; install that first, or the path
# unit's runs fail with "unrecognized arguments: --rate-request". The running
# endpoint is NOT restarted: `sudo systemctl restart usb16x16-dante` puts the
# owner, plugin and configs in service (the start check judges that start),
# `sudo systemctl restart usb-16x16.service` for a fresh anchor. Replaced files
# are kept beside the start wrapper as *.arbiter-previous.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$script_dir/.." && pwd)
libexec=/usr/local/libexec/usb16x16-dante
unit=usb16x16-dante.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
# source | new hash | installed path | mode | hash it replaces (- for a new file) | where the old one is kept
files="$base/owner/usb16x16-dante-owner-rate4|c8b484acac083f78c35597e0273f63dabe0544550bc9d942fd495a075a6adb28|$libexec/usb16x16-dante-owner|755|6287955840f747cdb70f3bc43b1ee26e79ca229f930e4a2534e85d91a4cb41a0|$libexec/usb16x16-dante-owner.arbiter-previous
$base/plugins/xrun-option-retry1-confirm-rate-arbiter/libasound_module_pcm_inferno.so|c6b012ae4529da759e29e9d43660c7df03b0cc9d5d308c8364595fa33c30ee8e|/usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so|644|d3a6b40a162e5b3ce9f6abae36cc371a5ed0ede73133e844b1f34bcd0148a355|$libexec/libasound_module_pcm_inferno.so.arbiter-previous
$base/config/asound-inferno-owner-rate48-arbiter.conf|0a1688e18c4ffa2c851719fc8230cbe950e3b936afd1fda29040d6118573ffd1|/etc/usb16x16/dante/asound-inferno-owner.conf|644|7beabf1af983e82e73ba8e0ed4f6a491ec3d4a0bdf313f846ef8cd59a4291b22|$libexec/asound-inferno-owner.conf.arbiter-previous
$script_dir/usb16x16-dante-start-transport|a6c3a1972ca6bbad335194dee436b1a611e84c7918b4e126a1f48650570e13f6|$libexec/usb16x16-dante-start|755|882f48acd4d795eb2243e08785198204d86c9cf232ab3141e92b7dac4835f66b|$libexec/usb16x16-dante-start.arbiter-previous
$script_dir/transport-rate-requests.conf|1434f79f7d5c4d0c877a0f7a1bcd6732db98b8096c1793df50952c119c09a105|/etc/usb16x16/dante/transport.conf|644|821bc306274ff374a739edc9e3e488bf164bdc478b0ae3e98735efa6969ef5f0|$libexec/transport.conf.arbiter-previous
$script_dir/usb16x16-dante-rate.path|f3ec747c3ee1e8298984d26d440ac20f8672ba481d7fb4f8f97e06c4ceb7ee59|/etc/systemd/system/usb16x16-dante-rate.path|644|-|-
$script_dir/usb16x16-dante-rate.service|a6971bae777799dc998e972817f1dcb7e8f80104f0e609bf71461e3ce816b84f|/etc/systemd/system/usb16x16-dante-rate.service|644|-|-"

report() {
  echo "$unit is $(systemctl is-active "$unit" || true), not restarted; usb16x16-dante-rate.path is $(systemctl is-active usb16x16-dante-rate.path || true)"
  echo "installed now: owner $(sha256_of "$libexec/usb16x16-dante-owner" | cut -c1-8), plugin $(sha256_of /usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so | cut -c1-8), config $(sha256_of /etc/usb16x16/dante/asound-inferno-owner.conf | cut -c1-8), wrapper $(sha256_of "$libexec/usb16x16-dante-start" | cut -c1-8), transport.conf $(sha256_of /etc/usb16x16/dante/transport.conf | cut -c1-8)"
}

if [ "${1:-}" = rollback ]; then
  systemctl disable --now usb16x16-dante-rate.path 2>/dev/null || true
  echo "$files" | while IFS='|' read -r source new installed mode old previous; do
    if [ "$old" = - ]; then
      rm -f "$installed"
      echo "removed $installed"
      continue
    fi
    [ -f "$previous" ] || { echo "no previous copy at $previous" >&2; exit 3; }
    [ "$(sha256_of "$previous")" = "$old" ] || { echo "$previous is not $(echo "$old" | cut -c1-8); refusing" >&2; exit 4; }
    install -o root -g root -m "$mode" "$previous" "$installed.new"
    mv -f "$installed.new" "$installed"
    echo "put back $installed ($(sha256_of "$installed" | cut -c1-8))"
  done
  systemctl daemon-reload
  report
  exit 0
fi

# Everything is checked before anything is written.
echo "$files" | while IFS='|' read -r source new installed mode old previous; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
  if [ "$old" = - ]; then
    [ ! -e "$installed" ] || [ "$(sha256_of "$installed")" = "$new" ] ||
      { echo "$installed exists and is not the file this installs; refusing" >&2; exit 4; }
    continue
  fi
  current=$(sha256_of "$installed")
  [ "$current" = "$new" ] || [ "$current" = "$old" ] ||
    { echo "$installed is $(echo "$current" | cut -c1-8), neither the $(echo "$old" | cut -c1-8) this replaces nor the new one; refusing" >&2; exit 4; }
done
# The new wrapper must accept the installed owner.conf with the new transport.conf.
USB16X16_DANTE_TRANSPORT="$script_dir/transport-rate-requests.conf" "$script_dir/usb16x16-dante-start-transport" --print >/dev/null ||
  { echo "the new wrapper refuses the installed owner.conf with this transport.conf; nothing changed" >&2; exit 4; }
# The units run the applier's rate kind; refuse if the installed applier has none.
grep -q -- '--rate-request' /usr/local/bin/usb16x16-apply ||
  { echo "/usr/local/bin/usb16x16-apply has no --rate-request: install web-control first; nothing changed" >&2; exit 4; }

echo "$files" | while IFS='|' read -r source new installed mode old previous; do
  if [ "$old" != - ] && [ "$(sha256_of "$installed")" = "$old" ]; then
    install -o root -g root -m "$mode" "$installed" "$previous"
  fi
  install -o root -g root -m "$mode" "$source" "$installed.new"
  mv -f "$installed.new" "$installed"
  echo "installed $installed ($(sha256_of "$installed" | cut -c1-8))"
done
systemctl daemon-reload
systemctl enable --now usb16x16-dante-rate.path
report
