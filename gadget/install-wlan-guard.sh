#!/bin/bash
# Install or remove the wireless management guard (usb16x16-wlan-guard and
# its unit), and nothing else. Run with sudo from the directory that holds
# the three files (on the author's Pi: ~/usb-16x16-work/gadget/).
#
#   sudo ./install-wlan-guard.sh            install the two files pinned below, enable and start
#   sudo ./install-wlan-guard.sh rollback   stop, disable and remove them; BSS transition back on
#   ./install-wlan-guard.sh status          what is installed and what the link looks like
#
# Management only: no audio service is restarted and eth0 is not touched.
# Starting the guard may re-associate wlan0 once (a few seconds), when the
# supplicant's disable_btm is not already 1.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
guard_new=89ec54846b91b6110ce032c66ec0e824b66fbb2e40c3e6f8237bdbb06d8938ba
unit_new=d1cd33d6e246f2a7bc3ed8e0810bd2f8a5ee64284c77f7f6f7b58873b863bf9d
guard=/usr/local/sbin/usb16x16-wlan-guard
unit=/etc/systemd/system/usb16x16-wlan-guard.service
ifname=wlan0
sha256_of() { sha256sum "$1" | awk '{print $1}'; }
short() { if [ -f "$1" ]; then sha256_of "$1" | cut -c1-8; else echo absent; fi; }

report() {
  echo "guard $(short "$guard"), unit $(short "$unit"), service $(systemctl is-active usb16x16-wlan-guard.service 2>/dev/null || true)"
  echo "disable_btm $(/usr/sbin/wpa_cli -i $ifname get disable_btm 2>/dev/null || echo unreadable); $ifname $(nmcli -t -f GENERAL.STATE device show $ifname 2>/dev/null | cut -d: -f2)"
  echo "usb16x16-dante is $(systemctl is-active usb16x16-dante.service 2>/dev/null || true)"
}

case "${1:-install}" in
  status) report; exit 0 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

case "${1:-install}" in
  rollback)
    systemctl disable --now usb16x16-wlan-guard.service 2>/dev/null || true
    rm -f "$guard" "$unit"
    systemctl daemon-reload
    /usr/sbin/wpa_cli -i $ifname set disable_btm 0 >/dev/null 2>&1 || true
    echo "removed; disable_btm set back to 0 (it applies from the next association)"
    report
    ;;
  install)
    for f in usb16x16-wlan-guard usb16x16-wlan-guard.service; do
      [ -r "$script_dir/$f" ] || { echo "missing source: $script_dir/$f" >&2; exit 3; }
    done
    [ "$(sha256_of "$script_dir/usb16x16-wlan-guard")" = "$guard_new" ] || { echo "hash mismatch: usb16x16-wlan-guard" >&2; exit 4; }
    [ "$(sha256_of "$script_dir/usb16x16-wlan-guard.service")" = "$unit_new" ] || { echo "hash mismatch: usb16x16-wlan-guard.service" >&2; exit 4; }
    install -o root -g root -m 755 "$script_dir/usb16x16-wlan-guard" "$guard"
    install -o root -g root -m 644 "$script_dir/usb16x16-wlan-guard.service" "$unit"
    systemctl daemon-reload
    systemctl enable --quiet usb16x16-wlan-guard.service
    systemctl restart usb16x16-wlan-guard.service
    sleep 3
    report
    ;;
  *) echo "usage: $0 [install|rollback|status]" >&2; exit 2 ;;
esac
