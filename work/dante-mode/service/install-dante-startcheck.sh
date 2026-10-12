#!/bin/bash
# Install or remove the Dante start check: a script and a oneshot unit that
# the endpoint's unit pulls in at each of its starts. Nothing of the accepted
# endpoint is changed: usb16x16-dante.service, the owner, the wrapper, the
# plugin, the configs and Statime stay as they are. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-startcheck.sh            install and enable the pair pinned below
#   sudo ./install-dante-startcheck.sh rollback   disable and remove them
#
# Installing does not restart or judge the running endpoint: the check runs
# from the endpoint's next start on. To judge the start that is running now,
# `sudo systemctl start usb16x16-dante-startcheck` (it restarts the endpoint
# if that start is losing packets). Its verdicts are in
# `journalctl -u usb16x16-dante-startcheck` and, one line, in
# /run/usb16x16-dante-startcheck/status.
#
# 2026-10-12: about one endpoint start in three comes up with a return flow
# missing some 800 packets a second (RESULTS.md, "The holes are packets from
# the Ferrofish that never reach the Pi"); the check reads eth0's received
# frame rate after each start and restarts the endpoint, at most four times,
# until a start is whole. A stopgap: the cause is not found.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
unit=usb16x16-dante-startcheck.service
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
# source | pinned hash | destination | mode
files="$script_dir/usb16x16-dante-startcheck|058e9177a4ce4009e474a277f336db64acb12bcc9b4584b4556a99a80646c56f|/usr/local/libexec/usb16x16-dante/usb16x16-dante-startcheck|755
$script_dir/$unit|e0ffc6222f730dd936561024487be31f5797cf1c19af07953dce031b8810d7a9|/etc/systemd/system/$unit|644"

report() {
  systemctl daemon-reload
  echo "$unit is $(systemctl is-enabled "$unit" 2>/dev/null || echo absent); usb16x16-dante is $(systemctl is-active usb16x16-dante.service || true), not restarted"
}

if [ "${1:-}" = rollback ]; then
  systemctl disable --now "$unit" 2>/dev/null || true
  echo "$files" | while IFS='|' read -r source hash destination mode; do rm -f "$destination"; echo "removed $destination"; done
  rm -rf /run/usb16x16-dante-startcheck
  report
  exit 0
fi

echo "$files" | while IFS='|' read -r source hash destination mode; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$hash" ] || { echo "hash mismatch: $source" >&2; exit 4; }
done
[ -d /usr/local/libexec/usb16x16-dante ] || { echo "no /usr/local/libexec/usb16x16-dante: the Dante service is not installed" >&2; exit 3; }
command -v ethtool >/dev/null || [ -x /usr/sbin/ethtool ] || { echo "ethtool is not installed; the check cannot read eth0's counters" >&2; exit 3; }
echo "$files" | while IFS='|' read -r source hash destination mode; do
  install -o root -g root -m "$mode" "$source" "$destination.new"
  mv -f "$destination.new" "$destination"
  echo "installed $destination ($(sha256_of "$destination" | cut -c1-8))"
done
systemctl daemon-reload
systemctl enable "$unit" >/dev/null 2>&1
report
