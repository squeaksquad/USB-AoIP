#!/bin/bash
# install-access.sh install|rollback|status
#
# For a unit built by the old installer chain (history/installers/), which
# `install.sh install` refuses: put the access work of 2026-11-10 on it and
# nothing else. In the manner of that chain: every file is checked against a
# pinned hash before and after, what it replaces is kept beside it, and
# `rollback` puts all of it back.
#
# What it replaces (docs/web/ACCESS.md says why):
#   /usr/local/bin/usb16x16-web             1.6.0 6b98e7cf -> 1.7.1 (or 1.7.0 e7f6ba5a -> 1.7.1,
#                                           on a unit that already has the first bundle)
#   /usr/local/bin/usb16x16-apply           1.8.0 347a7062 -> 1.9.0
#   /etc/systemd/system/usb16x16-web.service, usb16x16-apply.path, usb16x16-apply.service
#   the page: <work dir>/web-ui (index.html, style.css, the modules, compiler/)
# What it adds:
#   /var/spool/usb-aoip/inbox        root:<web user's group> 1730   requests from the page
#   /var/lib/usb16x16-apply          root 0755                      the applier's status and receipts
#   /etc/usb-aoip/web-auth           root:<web user's group> 0640   the page's logins, copied from
#                                    the file the old unit names; the old file is left where it is
#
# What it does not touch: the audio service, the clock service, the gadget,
# their configuration, the kernel modules, the rate arbiter's units. The page
# and the applier are stopped for a few seconds; audio keeps playing. The
# page stays on plain HTTP: TLS on this unit is a separate step.
#
# The new page and the new service go together: the service refuses a
# state-changing request without the header only the new page sends, so one
# is never installed without the other.
#
# Run from the bundle stage-access.sh made, on the unit:
#   sudo ./install-access.sh install
#   sudo ./install-access.sh rollback     back to 1.6.0 / 1.8.0 and the old page
#        ./install-access.sh status
# A login added after `install` is in /etc/usb-aoip/web-auth only; after a
# rollback the old file is in force again, without it.
#
# Acceptance (the operator's rule of 2026-10-29: these are outside the audio
# path): the page's own checks, a noise probe at 32 and one two-minute
# sixteen-channel soak. The last lines this prints say which.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=${USB_AOIP_TEST_ROOT:-}            # tests only: a directory standing in for /
systemctl=${USB_AOIP_TEST_SYSTEMCTL:-systemctl}
suffix=.pre-access
units=$root/etc/systemd/system
inbox=$root/var/spool/usb-aoip/inbox
state=$root/var/lib/usb16x16-apply
auth=$root/etc/usb-aoip/web-auth
# The hash of access.sha256, the list of everything in the bundle. stage-access.sh
# and install/test-render.sh both check it against the repository's files.
manifest_sha256=@MANIFEST@

# bundle file | installed path | mode | the hash the old chain left | hashes of earlier bundles
# A unit already on an earlier bundle is updated in place: its kept copies (the old
# chain's files) stay as they are, so `rollback` still goes all the way back.
files="bin/usb16x16-web|$root/usr/local/bin/usb16x16-web|755|6b98e7cfc171fb9c41d113dcdd1ad015f19b649b9289626a8e25cf4d4db71f8c|e7f6ba5a19922f75aef1669fa0afc5ec6217a44e7f1b4b62d10e54c3b71d4bec
bin/usb16x16-apply|$root/usr/local/bin/usb16x16-apply|755|347a70621f3c6bb9c10092f42ac52a0d280a756b14ba9c9f71175e7a3b28f3eb
units/usb16x16-web.service|$units/usb16x16-web.service|644|f7c7d48cab8b12b9b7ed9f5a920efc497e9874760cc9434c979c25ee68b59761
units/usb16x16-apply.path|$units/usb16x16-apply.path|644|6d53b053014a3cb7203de36f9e7472d370ccced6aee2c1d9a6d309b2d35bec61
units/usb16x16-apply.service|$units/usb16x16-apply.service|644|23cb5b2e371fa47af288f4f4867bd4c4b55b9f0d2133ea08ed864a97697f9dd2"

say()   { echo "install-access: $*"; }
die()   { echo "install-access: $2" >&2; exit "$1"; }
sha()   { if [ ! -f "$1" ]; then echo -; elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
short() { echo "$1" | cut -c1-8; }
field() { echo "$1" | cut -d'|' -f"$2"; }
new_of() { sed -n "s|^\([0-9a-f]\{64\}\)  $1\$|\1|p" "$here/access.sha256"; }
owned() { [ -n "$root" ] || chown "$@"; }   # ownership is not exercised under a test root
place() {   # place SOURCE DESTINATION MODE: a temporary file and a rename
  install -m "$3" "$1" "$2.new"
  owned root:root "$2.new"
  mv -f "$2.new" "$2"
}

web_unit=$units/usb16x16-web.service
unit_value() { sed -n "$1" "$2" 2>/dev/null | head -1; }

status() {
  local line dest old new now state_word
  while IFS= read -r line; do
    dest=$(field "$line" 2); old=$(field "$line" 4); new=$(new_of "$(field "$line" 1)"); now=$(sha "$dest")
    if [ "$now" = "$new" ]; then state_word=new; elif [ "$now" = "$old" ]; then state_word=old
    elif [ -n "$now" ] && [[ " $(field "$line" 5) " == *" $now "* ]]; then state_word="earlier bundle ($(short "$now"))"
    else state_word="NEITHER ($(short "$now"))"; fi
    printf '  %-52s %s   kept: %s\n' "${dest#"$root"}" "$state_word" "$(short "$(sha "$dest$suffix")")"
  done <<< "$files"
  echo "  inbox $( [ -d "$inbox" ] && echo present || echo absent ), state $( [ -d "$state" ] && echo present || echo absent ), logins $( [ -f "$auth" ] && echo present || echo absent )"
  for u in usb16x16-web.service usb16x16-apply.path usb16x16-dante-rate.path usb16x16-dante.service; do
    printf '  %-28s %s\n' "$u" "$("$systemctl" is-active "$u" 2>/dev/null || true)"
  done
}

case "${1:-}" in
  status) [ -r "$here/access.sha256" ] || die 2 "no access.sha256 beside this script"; status; exit 0 ;;
  install|rollback) mode=$1 ;;
  *) echo "usage: $0 install|rollback|status" >&2; exit 2 ;;
esac
[ -n "$root" ] || [ "$(id -u)" -eq 0 ] || die 2 "run with sudo"

# The bundle is the one this script was written for.
[ "$(sha "$here/access.sha256")" = "$manifest_sha256" ] || die 5 "access.sha256 is not the list this script pins ($(short "$manifest_sha256")); stage the bundle again"
while read -r want path; do
  [ -n "$want" ] || continue
  [ "$(sha "$here/$path")" = "$want" ] || die 5 "$path in the bundle is not $(short "$want"); stage the bundle again"
done < "$here/access.sha256"

# The unit as the old chain left it: who the page runs as, and where its files are.
[ -r "$web_unit" ] || die 3 "$web_unit is not there: this is not a unit the old chain built"
web_user=$(unit_value 's/^User=//p' "$web_unit")
web_group=$(unit_value 's/^Group=//p' "$web_unit")
work=$(unit_value 's|.*--static \(/[^ ]*\)/web-ui.*|\1|p' "$web_unit")
[ -n "$web_user" ] && [ -n "$web_group" ] && [ -n "$work" ] || die 3 "could not read the page's user and directory from $web_unit"
[ -n "$root" ] && page=$root$work/web-ui || page=$work/web-ui
[ -d "$page" ] || die 3 "the page's directory $page is not there"
# The bundle's units carry the development unit's values; on any other unit they would be wrong.
[ "$(unit_value 's/^User=//p' "$here/units/usb16x16-web.service")" = "$web_user" ] &&
  [ "$(unit_value 's|.*--static \(/[^ ]*\)/web-ui.*|\1|p' "$here/units/usb16x16-web.service")" = "$work" ] ||
  die 3 "the bundle was made for another unit (its web unit names another user or directory)"

for unit in usb16x16-apply.service usb16x16-dante-rate.service; do
  case "$("$systemctl" is-active "$unit" 2>/dev/null || true)" in
    active|activating|deactivating|reloading) die 4 "$unit is running an operation; try again when it has finished" ;;
  esac
done
[ "$("$systemctl" is-active usb16x16-dante-candidate.service 2>/dev/null || true)" != active ] || die 4 "usb16x16-dante-candidate is running; stop it first"

stop_page()  { "$systemctl" stop usb16x16-web.service usb16x16-apply.path usb16x16-dante-rate.path 2>/dev/null || true; }
start_page() {
  "$systemctl" daemon-reload
  "$systemctl" start usb16x16-dante-rate.path usb16x16-apply.path
  "$systemctl" restart usb16x16-web.service
}

if [ "$mode" = rollback ]; then
  while IFS= read -r line; do
    dest=$(field "$line" 2); old=$(field "$line" 4)
    [ "$(sha "$dest$suffix")" = "$old" ] || die 5 "no verified ${dest#"$root"}$suffix ($(short "$old")); nothing changed"
  done <<< "$files"
  [ -d "$page$suffix" ] || die 5 "no kept page at $page$suffix; nothing changed"
  stop_page
  while IFS= read -r line; do
    dest=$(field "$line" 2); place "$dest$suffix" "$dest" "$(field "$line" 3)"
    [ "$(sha "$dest")" = "$(field "$line" 4)" ] || die 6 "${dest#"$root"} did not verify after the restore"
  done <<< "$files"
  # Restored and verified: the kept copies have done their work.
  while IFS= read -r line; do rm -f "$(field "$line" 2)$suffix"; done <<< "$files"
  rm -rf "$page.access-new"
  mv "$page" "$page.access-new"
  mv "$page$suffix" "$page"
  rm -rf "$page.access-new"
  rmdir "$inbox" 2>/dev/null || true     # only if nothing is waiting in it
  start_page
  say "rolled back: web 1.6.0, applier 1.8.0 and the old page. Left in place: $state, ${auth#"$root"} (the old login file is in force again)."
  status; exit 0
fi

# install
installed_new=0; installed_old=0; installed_earlier=0; count=0
while IFS= read -r line; do
  count=$((count + 1)); now=$(sha "$(field "$line" 2)")
  if [ "$now" = "$(new_of "$(field "$line" 1)")" ]; then installed_new=$((installed_new + 1))
  elif [ "$now" = "$(field "$line" 4)" ]; then installed_old=$((installed_old + 1))
  elif [[ " $(field "$line" 5) " == *" $now "* ]]; then installed_earlier=$((installed_earlier + 1)); fi
done <<< "$files"
page_current=1
( cd "$here/web-ui" && find . -type f ) | while read -r f; do cmp -s "$here/web-ui/$f" "$page/$f" || exit 1; done || page_current=0
if [ "$installed_new" = "$count" ] && [ "$page_current" = 1 ]; then say "already installed"; status; exit 0; fi
if [ "$installed_old" = "$count" ]; then
  update=0     # the unit as the old chain left it
elif [ "$installed_old" = 0 ] && [ $((installed_new + installed_earlier)) = "$count" ]; then
  update=1     # the unit already has an earlier bundle
else
  die 5 "the installed files are not all the ones this replaces (see: $0 status); nothing changed"
fi
if [ "$update" = 1 ]; then
  while IFS= read -r line; do
    kept=$(field "$line" 2)$suffix
    [ "$(sha "$kept")" = "$(field "$line" 4)" ] || die 5 "${kept#"$root"} is not the old chain's file; this unit was not updated by this installer; nothing changed"
  done <<< "$files"
  [ -d "$page$suffix" ] || die 5 "no kept page at $page$suffix; nothing changed"
  [ -s "$auth" ] || die 3 "no logins at ${auth#"$root"}"
else
  while IFS= read -r line; do
    kept=$(field "$line" 2)$suffix
    [ ! -e "$kept" ] || [ "$(sha "$kept")" = "$(field "$line" 4)" ] || die 5 "${kept#"$root"} exists with another hash; nothing changed"
  done <<< "$files"
  [ ! -e "$page$suffix" ] || die 5 "$page$suffix exists already; nothing changed"
  old_spool=$( [ -n "$root" ] && echo "$root$work/web-apply" || echo "$work/web-apply" )
  [ ! -e "$old_spool/request.json" ] || die 4 "a request is waiting in $old_spool; let it finish first"
  old_auth=$(unit_value 's/.*--auth-file \([^ ]*\).*/\1/p' "$web_unit")
  [ -n "$root" ] && old_auth=$root$old_auth
  [ -s "$old_auth" ] || [ -s "$auth" ] || die 3 "no logins found at $old_auth: the new service would refuse to start"
fi

stop_page
# 1. the directories and the login file
install -d -m 755 "$root/var/spool/usb-aoip" "$state" "$root/etc/usb-aoip"
install -d -m 1730 "$inbox"
owned root:root "$root/var/spool/usb-aoip" "$state" "$root/etc/usb-aoip"
owned root:"$web_group" "$inbox"
if [ ! -s "$auth" ]; then
  install -m 640 "${old_auth:?}" "$auth"
  owned root:"$web_group" "$auth"
fi
# 2. keep what is there. From the old chain's files: the copies `rollback` restores.
#    Always: a copy of this moment, which a failure below puts straight back.
undo=.access-undo
while IFS= read -r line; do
  dest=$(field "$line" 2)
  [ "$update" = 1 ] || [ -e "$dest$suffix" ] || cp -p "$dest" "$dest$suffix"
  cp -p "$dest" "$dest$undo"
done <<< "$files"
[ "$update" = 1 ] || cp -a "$page" "$page$suffix"
rm -rf "$page$undo"; cp -a "$page" "$page$undo"
drop_undo() { while IFS= read -r line; do rm -f "$(field "$line" 2)$undo"; done <<< "$files"; rm -rf "$page$undo"; }
# 3. the new files
fail() {   # put this moment back and say why
  while IFS= read -r line; do dest=$(field "$line" 2); place "$dest$undo" "$dest" "$(field "$line" 3)"; done <<< "$files"
  rm -rf "$page"; mv "$page$undo" "$page"
  if [ "$update" = 0 ]; then
    while IFS= read -r line; do rm -f "$(field "$line" 2)$suffix"; done <<< "$files"
    rm -rf "$page$suffix"
  fi
  drop_undo
  start_page || true
  die 7 "$1; what was installed before was put back"
}
while IFS= read -r line; do
  src=$here/$(field "$line" 1); dest=$(field "$line" 2)
  place "$src" "$dest" "$(field "$line" 3)"
  [ "$(sha "$dest")" = "$(new_of "$(field "$line" 1)")" ] || fail "${dest#"$root"} did not verify"
done <<< "$files"
mkdir -p "$page/compiler"
( cd "$here/web-ui" && find . -type f ) | while read -r f; do
  install -m 644 "$here/web-ui/$f" "$page/$f.new"
  owned "$web_user":"$web_group" "$page/$f.new"
  mv -f "$page/$f.new" "$page/$f"
done
python3 "$root/usr/local/bin/usb16x16-apply" --help >/dev/null 2>&1 || fail "the new applier does not run"
python3 "$root/usr/local/bin/usb16x16-web" --help >/dev/null 2>&1 || fail "the new web service does not run"
start_page || fail "the page's units did not start"
sleep "${USB_AOIP_TEST_SETTLE:-4}"
[ -n "$root" ] || [ "$("$systemctl" is-active usb16x16-web.service)" = active ] || fail "usb16x16-web is not active (journalctl -u usb16x16-web -n 30)"

drop_undo
say "installed: web $(short "$(new_of bin/usb16x16-web)"), applier $(short "$(new_of bin/usb16x16-apply)"), the page. The old chain's files are kept as *$suffix."
status
cat <<EOF
install-access: the audio service was not restarted. To accept this:
  1. Reload the page in the browser (a full reload: it must fetch the new modules) and sign in.
  2. On the page: the status pill reads CONNECTED; the meters move with audio; the log panel reads.
  3. One Apply to a preset and back to direct; one live edit and Commit.
  4. One rate move from the Mac and one from Dante Controller (the arbiter runs through the new applier).
  5. From the Mac: the noise probe at 32, then: dante/measure-candidate.sh soak 120 32
  Anything wrong: sudo ./install-access.sh rollback
EOF
