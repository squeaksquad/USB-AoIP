#!/bin/bash
# Install or remove the NetworkManager drop-in that keeps eth0's connection
# through a carrier loss, and nothing else. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-eth0-carrier.sh            install the drop-in pinned below
#   sudo ./install-eth0-carrier.sh rollback   remove it
#
# Either way NetworkManager is asked to re-read its configuration (a reload,
# not a restart: no interface is taken down, the endpoint is not touched).
# If the setting turns out to need a restart of NetworkManager to reach a
# device that is already active, that is a separate, deliberate step.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
source=$script_dir/90-usb16x16-eth0-carrier.conf
new=3a1842a6390e03c1f272675b725e2c94d1d74c558adb8a98770bef9e8af13661
installed=/etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

report() {
  systemctl reload NetworkManager
  sleep 1
  echo "eth0: $(nmcli -g GENERAL.STATE device show eth0), $(nmcli -g GENERAL.CONNECTION device show eth0); usb16x16-dante is $(systemctl is-active usb16x16-dante.service || true)"
}

if [ "${1:-}" = rollback ]; then
  rm -f "$installed"
  echo "removed $installed"
  report
  exit 0
fi

[ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
[ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
if [ -f "$installed" ] && [ "$(sha256_of "$installed")" = "$new" ]; then
  echo "already installed: $(echo "$new" | cut -c1-8)"
  exit 0
fi
install -o root -g root -m 644 "$source" "$installed"
echo "installed $installed ($(sha256_of "$installed" | cut -c1-8))"
report
