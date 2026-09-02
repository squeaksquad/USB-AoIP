#!/bin/bash
# Make the Pi's systemd journal persistent so cold-boot timelines survive a
# reboot. Raspberry Pi OS ships Storage=volatile in
# /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf; a later
# drop-in in /etc overrides it. Idempotent; run once with sudo.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

dropin=/etc/systemd/journald.conf.d/50-persistent.conf
content='[Journal]
Storage=persistent
SystemMaxUse=256M
'

install -d -o root -g root -m 755 /etc/systemd/journald.conf.d
if [ -e "$dropin" ] && [ "$(cat "$dropin")" = "$(printf '%s' "$content")" ]; then
  echo "unchanged $dropin"
else
  printf '%s' "$content" > "$dropin.tmp"
  chmod 644 "$dropin.tmp"
  mv -f "$dropin.tmp" "$dropin"
  echo "installed $dropin"
fi
install -d -o root -g systemd-journal -m 2755 /var/log/journal
systemctl restart systemd-journald
journalctl --flush
effective=$(systemd-analyze cat-config systemd/journald.conf | grep -E '^\s*Storage=' | tail -1)
path=$(journalctl --header 2>/dev/null | grep -m1 '^File path' || true)
echo "effective: $effective"
echo "journal: $path"
case "$path" in
  *"/var/log/journal/"*) echo "journal is persistent" ;;
  *) echo "journal is NOT persistent" >&2; exit 1 ;;
esac
