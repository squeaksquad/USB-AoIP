#!/bin/bash
# Install usb16x16-dante-candidate, the launcher that runs a candidate build
# of the Dante owner by hand as the service user (see its header), and the
# rule that lets the operator's account run it without a password. Asked for
# by the operator on 2026-10-11 so that later sessions can try builds
# without him. Needs install-dante-service.sh to have been run (the service
# user, the installed plugin and config, the clock unit). Run once with sudo
# from ~/usb-16x16-work/dante-mode/service/.
#
# Rollback: sudo ./install-dante-candidate-launcher.sh remove
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
source="$script_dir/usb16x16-dante-candidate"
destination=/usr/local/sbin/usb16x16-dante-candidate
sudoers_destination=/etc/sudoers.d/usb16x16-dante-candidate
expected_sha256=252c07d80f4f219fc14e0516615d12ba16924562e64ab0f86885366aa474d2ee

if [ "${1:-}" = remove ]; then
  systemctl stop usb16x16-dante-candidate 2>/dev/null || true
  rm -f "$destination" "$sudoers_destination"
  echo "removed $destination and $sudoers_destination"
  exit 0
fi

if [ ! -r "$source" ] || [ "$(sha256sum "$source" | awk '{print $1}')" != "$expected_sha256" ]; then
  echo "launcher missing or hash mismatch: $source" >&2
  exit 3
fi
bash -n "$source"
getent passwd usb16x16-dante >/dev/null || { echo "no user usb16x16-dante; run install-dante-service.sh first" >&2; exit 4; }
[ -r /usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so ] || { echo "the Dante service is not installed" >&2; exit 4; }

sudoers_temporary=$(mktemp /tmp/usb16x16-dante-candidate-sudoers.XXXXXX)
trap 'rm -f "$sudoers_temporary"' EXIT HUP INT TERM
cat > "$sudoers_temporary" <<'RULE'
# Hand-runs of candidate Dante owner builds, as the service user with two
# capabilities and never as root (see /usr/local/sbin/usb16x16-dante-candidate).
bdimaio ALL=(root) NOPASSWD: /usr/local/sbin/usb16x16-dante-candidate
RULE
/usr/sbin/visudo -cf "$sudoers_temporary"

install -o root -g root -m 755 "$source" "$destination"
install -o root -g root -m 440 "$sudoers_temporary" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination"
echo "installed $destination"
echo "installed $sudoers_destination"
