#!/bin/bash
# One-time, needs the Pi sudo password once. Installs stall-tuning.sh
# root-owned at a fixed path and adds an exact-command NOPASSWD rule for it,
# so the governor and IRQ levers can be driven from the Mac without a
# password: the same pattern the supervisor's start/stop/switch-profile
# and the candidate wrappers already use. The installed script is
# root-owned and hash-pinned here, so the rule cannot be widened without
# root. Nothing else gains passwordless sudo; installing a new bridge
# binary still needs the password by design.
#
#   sudo ./install-stall-tuning.sh ./stall-tuning.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
if [ "$#" -ne 1 ]; then
  echo "usage: $0 STALL_TUNING_SCRIPT" >&2
  exit 2
fi

source=$1
destination=/usr/local/sbin/usb16x16-stall-tuning
sudoers_destination=/etc/sudoers.d/usb16x16-stall-tuning
expected_sha256=bde240b8000ee1f91ac8e9ed2c9fc969764a11c47b3f81b2dc2cf8da112cd7c8

if [ "$(sha256sum "$source" | awk '{print $1}')" != "$expected_sha256" ]; then
  echo "stall-tuning.sh hash mismatch" >&2
  exit 3
fi
bash -n "$source"

sudoers_temporary=$(mktemp /tmp/usb16x16-stall-tuning-sudoers.XXXXXX)
trap 'rm -f "$sudoers_temporary"' EXIT HUP INT TERM
cat > "$sudoers_temporary" <<'RULE'
bdimaio ALL=(root) NOPASSWD: /usr/local/sbin/usb16x16-stall-tuning
RULE
/usr/sbin/visudo -cf "$sudoers_temporary"

install -o root -g root -m 755 "$source" "$destination"
install -o root -g root -m 440 "$sudoers_temporary" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination"

echo "installed $destination ($expected_sha256)"
echo "installed $sudoers_destination"
