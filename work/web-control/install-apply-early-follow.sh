#!/bin/bash
# install-apply-early-follow.sh: usb16x16-apply 1.8.0 in place of 1.7.0 (RATE_REPORT_PLAN.md,
# "Early follow"). 1.8.0 asks the Mac to follow a Dante-side or page rate move as soon as the
# endpoint runs at the new rate, before the 15 s settle, and sends it back if the move rolls back.
#
#   sudo ./install-apply-early-follow.sh install    1.8.0, keeping 1.7.0 as usb16x16-apply.pre-early-follow
#   sudo ./install-apply-early-follow.sh rollback   1.7.0 back
#   ./install-apply-early-follow.sh status          the installed and kept hashes
#
# Run from a directory holding the 1.8.0 copy as usb16x16-apply. Only the applier changes; its
# units start it fresh for each request, so nothing is restarted.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
installed=/usr/local/bin/usb16x16-apply
previous=/usr/local/bin/usb16x16-apply.pre-early-follow
new_apply=347a70621f3c6bb9c10092f42ac52a0d280a756b14ba9c9f71175e7a3b28f3eb
old_apply=1a85bd3db2490107ef906595cd62b8dc9d38942983bf32c2f7d1a9cebf918b10

sha256() { [ -e "$1" ] && sha256sum "$1" | awk '{print $1}' || echo -; }
short() { echo "$1" | cut -c1-8; }
status() { echo "usb16x16-apply: $(short "$(sha256 "$installed")")  kept: $(short "$(sha256 "$previous")")  (1.8.0 $(short "$new_apply"), 1.7.0 $(short "$old_apply"))"; }
put_file() {   # put_file SOURCE DESTINATION MODE: temp-and-rename
  install -o root -g root -m "$3" "$1" "$2.new"
  mv -f "$2.new" "$2"
}

case "${1:-}" in
  status) status; exit 0;;
  install|rollback) mode=$1;;
  *) echo "usage: $0 install|rollback|status" >&2; exit 2;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 2; }
for unit in usb16x16-apply.service usb16x16-dante-rate.service; do
  case "$(systemctl is-active "$unit")" in
    active|activating|deactivating|reloading) echo "$unit is running an operation; retry when it has finished" >&2; exit 4;;
  esac
done

if [ "$mode" = rollback ]; then
  [ "$(sha256 "$previous")" = "$old_apply" ] || { echo "no verified $previous; nothing changed" >&2; exit 5; }
  current=$(sha256 "$installed")
  [ "$current" = "$new_apply" ] || [ "$current" = "$old_apply" ] || { echo "usb16x16-apply is neither 1.8.0 nor 1.7.0; nothing changed" >&2; exit 5; }
  put_file "$previous" "$installed" 0755
  [ "$(sha256 "$installed")" = "$old_apply" ] || { echo "restore did not verify" >&2; exit 6; }
  echo "rolled back to usb16x16-apply 1.7.0"; status; exit 0
fi

[ "$(sha256 "$here/usb16x16-apply")" = "$new_apply" ] || { echo "usb16x16-apply copy is not 1.8.0 $(short "$new_apply")" >&2; exit 5; }
if [ "$(sha256 "$installed")" = "$new_apply" ]; then echo "1.8.0 is already installed"; status; exit 0; fi
[ "$(sha256 "$installed")" = "$old_apply" ] || { echo "installed usb16x16-apply is not 1.7.0 $(short "$old_apply"); nothing changed" >&2; exit 5; }
[ ! -e "$previous" ] || [ "$(sha256 "$previous")" = "$old_apply" ] || { echo "$previous exists with another hash; nothing changed" >&2; exit 5; }
install -o root -g root -m 0755 "$installed" "$previous"
put_file "$here/usb16x16-apply" "$installed" 0755
if [ "$(sha256 "$installed")" != "$new_apply" ]; then
  put_file "$previous" "$installed" 0755
  echo "the installed copy did not verify; 1.7.0 put back" >&2; exit 7
fi
"$installed" --help >/dev/null || { put_file "$previous" "$installed" 0755; echo "1.8.0 does not run; 1.7.0 put back" >&2; exit 7; }
echo "installed usb16x16-apply 1.8.0 $(short "$new_apply"); kept 1.7.0 as $previous"; status
