#!/bin/bash
# Install usb16x16-dante-catch, the bounded tmpfs capture of the Dante flows
# (see its header), and the rule that lets the operator's account run it
# without a password, so a session can arm and stop a catch by itself (the
# operator's ask of 2026-10-30: sessions run their own root test steps). Run
# once with sudo from ~/usb-16x16-work/dante-mode/service/.
#
# Rollback: sudo ./install-dante-catch.sh remove
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
source="$script_dir/usb16x16-dante-catch"
destination=/usr/local/sbin/usb16x16-dante-catch
sudoers_destination=/etc/sudoers.d/usb16x16-dante-catch
expected_sha256=58be3664406f1c44ed46ff6ed123ffa2ecec434df54dbc159cf3cafd3f6e4021

if [ "${1:-}" = remove ]; then
  [ -x "$destination" ] && "$destination" stop >/dev/null 2>&1 || true
  rm -f "$destination" "$sudoers_destination"
  rm -rf /dev/shm/usb16x16-catch
  echo "removed $destination and $sudoers_destination"
  exit 0
fi

if [ ! -r "$source" ] || [ "$(sha256sum "$source" | awk '{print $1}')" != "$expected_sha256" ]; then
  echo "catch script missing or hash mismatch: $source" >&2
  exit 3
fi
bash -n "$source"
command -v tcpdump >/dev/null || { echo "tcpdump is not installed" >&2; exit 4; }

sudoers_temporary=$(mktemp /tmp/usb16x16-dante-catch-sudoers.XXXXXX)
trap 'rm -f "$sudoers_temporary"' EXIT HUP INT TERM
cat > "$sudoers_temporary" <<'RULE'
# A bounded tcpdump ring of the Dante flows in /dev/shm/usb16x16-catch, armed
# and stopped by a session (see /usr/local/sbin/usb16x16-dante-catch).
bdimaio ALL=(root) NOPASSWD: /usr/local/sbin/usb16x16-dante-catch
RULE
/usr/sbin/visudo -cf "$sudoers_temporary"

install -o root -g root -m 755 "$source" "$destination"
install -o root -g root -m 440 "$sudoers_temporary" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination"
echo "installed $destination"
echo "installed $sudoers_destination"
