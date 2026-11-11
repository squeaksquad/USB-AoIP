#!/bin/bash
# Install or remove the sysctl file that stops compaction moving locked pages
# (vm.compact_unevictable_allowed = 0), and nothing else. Run with sudo from
# ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-compaction-sysctl.sh            install the file pinned below and apply it
#   sudo ./install-compaction-sysctl.sh rollback   remove it and put the kernel's default (1) back
#
# Either way the value is written to the running kernel at once; no service
# is restarted and the endpoint is not touched. The file makes the value
# survive a reboot (systemd-sysctl reads /etc/sysctl.d/ at boot).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
source=$script_dir/90-usb16x16-compaction.conf
new=2db7c8b9a6f2d9e24e7df0401d507e3c9b852231b7aea1daea9753c8fa04e661
installed=/etc/sysctl.d/90-usb16x16-compaction.conf
knob=/proc/sys/vm/compact_unevictable_allowed
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

report() {
  echo "vm.compact_unevictable_allowed is $(cat "$knob"); usb16x16-dante is $(systemctl is-active usb16x16-dante.service || true)"
}

if [ "${1:-}" = rollback ]; then
  rm -f "$installed"
  echo "removed $installed"
  echo 1 > "$knob"
  report
  exit 0
fi

[ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
[ "$(sha256_of "$source")" = "$new" ] || { echo "hash mismatch: $source" >&2; exit 4; }
# No other file may set the same key: the last one read at boot would win.
if others=$(grep -ls 'compact_unevictable_allowed' /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf 2>/dev/null | grep -vx "$installed"); then
  echo "another file sets this key: $others" >&2
  exit 5
fi
if [ -f "$installed" ] && [ "$(sha256_of "$installed")" = "$new" ]; then
  echo "already installed: $(echo "$new" | cut -c1-8)"
else
  install -o root -g root -m 644 "$source" "$installed"
  echo "installed $installed ($(sha256_of "$installed" | cut -c1-8))"
fi
/usr/sbin/sysctl -q -p "$installed"
report
