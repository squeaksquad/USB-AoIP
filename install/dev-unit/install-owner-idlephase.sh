#!/bin/bash
# install-owner-idlephase.sh install|rollback|status
#
# For the development unit (the author's Pi, built by the old installer chain):
# put the owner with the --idle-phase option in its service form in place, and
# nothing else. In the manner of install-owner-monitor.sh: every file is checked
# against a pinned hash and every installed one against the hash it is expected
# to replace; usb16x16-dante.service is stopped for the swap; what is replaced is
# kept beside it as *.idlephase-previous; `rollback` puts it back.
#
# What it replaces, the three together or none:
#   /usr/local/libexec/usb16x16-dante/usb16x16-dante-owner   bc486911 (the monitor block, installed
#                                    by install-owner-monitor.sh) -> bb3cd6ca, built by
#                                    build-owner-idlephase.sh: dante/owner/main.cpp 8c9bf80e with
#                                    dante/owner/idle-phase.patch (main.cpp 4d885b76)
#   /usr/local/libexec/usb16x16-dante/usb16x16-dante-start   df6a1b0b (2026-11-01) -> WRAPPER_NEW,
#                                    dante/service/usb16x16-dante-start-transport with the
#                                    IDLE_PHASE key (passes nothing without it)
#   /etc/usb16x16/dante/transport.conf                       add1bc21 (transport-rate882.conf) ->
#                                    TRANSPORT_NEW, dante/service/transport-idlephase.conf:
#                                    the same with IDLE_PHASE=60 (PROJECT_HANDOFF.md, MEASURED 2026-11-20)
# What it leaves alone: the DSP runner 46f36659 (bridge_core.cpp is unchanged), owner.conf,
# the plugin, Statime, the units, the page.
#
# Order of operations: this goes on AFTER install-owner-monitor.sh (it replaces that one's
# owner bc486911 and refuses any other), and its rollback comes BEFORE that one's (whose
# install and rollback require the start wrapper df6a1b0b this puts back).
#
# Refusals kept from install-owner-monitor.sh: sudo; the candidate launcher running; a rate
# change or an apply in progress; empty binary pin; a bundle that is not the pinned list; a
# built binary that is not the pinned build; a file that is neither the one replaced nor the
# new one. Dropped: the separate start-wrapper requirement (the wrapper is one of the three
# files swapped here, so its old and new hashes are checked as the owner's are); the runner
# (not swapped); the rollback refusal for a running preset with a monitor section (bc486911,
# which rollback returns to, has the monitor block and loads such a preset).
#
# Acceptance: this changes the owner and its command line, so it is an audio-path change:
# the full battery (four loaded 800-impulse runs and a ten-minute sixteen-channel soak) at
# 48 kHz and at 96 kHz is owed before ACCEPTED.
#
#   sudo ./install-owner-idlephase.sh install
#   sudo ./install-owner-idlephase.sh rollback
#        ./install-owner-idlephase.sh status       read-only
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=${USB_AOIP_TEST_ROOT:-}            # tests only: a directory standing in for /
systemctl=${USB_AOIP_TEST_SYSTEMCTL:-systemctl}
journalctl=${USB_AOIP_TEST_JOURNALCTL:-journalctl}
settle=${USB_AOIP_TEST_SETTLE:-12}
suffix=.idlephase-previous
unit=usb16x16-dante.service
libexec=$root/usr/local/libexec/usb16x16-dante
owner_path=$libexec/usb16x16-dante-owner
start_path=$libexec/usb16x16-dante-start
transport_path=$root/etc/usb16x16/dante/transport.conf
# The hash of owner-idlephase.sha256, the list of everything in the bundle but this script.
# stage-owner-idlephase.sh writes it in and checks the list against the repository's.
manifest_sha256=@MANIFEST@

# The new owner: the candidate built on the author's Pi on 2026-11-20 (g++ Debian 14.2.0-19)
# and measured (PROJECT_HANDOFF.md, DONE and MEASURED 2026-11-20).
OWNER_NEW=bb3cd6ca413ad4b498d42f479a15db7b42ff6768c2eb2c587b4e4cc5572c0ff4
# The start wrapper and transport.conf in this bundle (service/).
WRAPPER_NEW=203c6fa54df5989286a52e52ab3e7ee291d4ef24cdfa48c389172bb895baf99f
TRANSPORT_NEW=6818176f2a7128264b453d985a1c0e3338f46bd5391c7fb5c4ffa1d426062948
# What they replace: install-owner-monitor.sh's OWNER_NEW; the start wrapper of 2026-11-01
# (install-dante-rate96-drop96.sh); transport-rate882.conf (install-dante-rate882.sh).
OWNER_OLD=bc48691122f2357606e2cd2a849cde4aee8c0ad6cb7998cad41aaa0c2f320b3e
WRAPPER_OLD=df6a1b0bd22679f8e26050dd4ea9759c18bf598bdac3c771eafcc5f7f1c6b495
TRANSPORT_OLD=add1bc21b3532cbd618fcac76a38aef554a0b66a3fcd69d42f628498fa48b192

say()   { echo "install-owner-idlephase: $*"; }
die()   { echo "install-owner-idlephase: $2" >&2; exit "$1"; }
sha()   { if [ ! -f "$1" ]; then echo -; elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
short() { echo "$1" | cut -c1-8; }

# Hashes the tests stand in for (a test cannot make a file that hashes to bc486911). Taken only
# with a stand-in root: on the unit the pins above are the only ones. The wrapper and transport
# pins are never overridden: the tests use the real files.
for var in OWNER_NEW OWNER_OLD; do
  test_var=USB_AOIP_TEST_$var
  [ -n "${!test_var:-}" ] || continue
  [ -n "$root" ] || die 2 "$test_var is for the tests and is taken only with USB_AOIP_TEST_ROOT; unset it"
  # EMPTY stands for a pin not yet made, so the refusal for one stays tested once the pins are in.
  if [ "${!test_var}" = EMPTY ]; then printf -v "$var" '%s' ''; else printf -v "$var" '%s' "${!test_var}"; fi
done

# name | installed path | the bundle's file | new | old | mode
files="owner|$owner_path|$here/out/usb16x16-dante-owner|$OWNER_NEW|$OWNER_OLD|755
wrapper|$start_path|$here/service/usb16x16-dante-start-transport|$WRAPPER_NEW|$WRAPPER_OLD|755
transport|$transport_path|$here/service/transport-idlephase.conf|$TRANSPORT_NEW|$TRANSPORT_OLD|644"
field() { echo "$1" | cut -d'|' -f"$2"; }
state_of() {   # new | old | other (short hash) | absent
  local now; now=$(sha "$1")
  if [ "$now" = - ]; then echo absent
  elif [ -n "$2" ] && [ "$now" = "$2" ]; then echo new
  elif [ "$now" = "$3" ]; then echo old
  else echo "other ($(short "$now"))"; fi
}
active() { "$systemctl" is-active "$1" 2>/dev/null || true; }

status() {
  local line path
  echo "  pins: owner $( [ -n "$OWNER_NEW" ] && short "$OWNER_NEW" || echo EMPTY ) (old $(short "$OWNER_OLD")), start wrapper $(short "$WRAPPER_NEW") (old $(short "$WRAPPER_OLD")), transport.conf $(short "$TRANSPORT_NEW") (old $(short "$TRANSPORT_OLD"))"
  while IFS= read -r line; do
    path=$(field "$line" 2)
    printf '  %-52s %-16s kept: %s   bundle: %s\n' "${path#"$root"}" "$(state_of "$path" "$(field "$line" 4)" "$(field "$line" 5)")" \
      "$(short "$(sha "$path$suffix")")" "$(short "$(sha "$(field "$line" 3)")")"
  done <<< "$files"
  for u in "$unit" usb16x16-dante-candidate.service usb16x16-dante-rate.service usb16x16-apply.service; do
    printf '  %-36s %s\n' "$u" "$(active "$u")"
  done
}

case "${1:-}" in
  status) status; exit 0 ;;
  install|rollback) mode=$1 ;;
  *) echo "usage: $0 install|rollback|status" >&2; exit 2 ;;
esac
[ -n "$root" ] || [ "$(id -u)" -eq 0 ] || die 2 "run with sudo"

[ "$(active usb16x16-dante-candidate.service)" != active ] || die 4 "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop); nothing changed"
for u in usb16x16-dante-rate.service usb16x16-apply.service; do
  case "$(active "$u")" in
    active|activating|deactivating|reloading) die 4 "$u is running an operation; try again when it has finished; nothing changed" ;;
  esac
done

restart() {
  local since start_line; since=$(date +%s)
  "$systemctl" reset-failed "$unit" 2>/dev/null || true
  "$systemctl" start "$unit"
  sleep "$settle"
  echo "  $unit is $(active "$unit")"
  echo "  owner $(short "$(sha "$owner_path")"), start wrapper $(short "$(sha "$start_path")"), transport.conf $(short "$(sha "$transport_path")")"
  start_line=$("$journalctl" -u "$unit" --since "@$since" --no-pager -o cat 2>/dev/null | grep '^START usb16x16-dante-owner' | head -1 || true)
  echo "  the owner's START line: $(echo "$start_line" | grep -o 'idle_phase_us=[-0-9]*' || echo 'no idle_phase_us= (an owner without the option, or no START line yet)')"
}
place() {   # place SOURCE DESTINATION MODE: a temporary file and a rename
  install -m "$3" "$1" "$2.new"
  [ -n "$root" ] || chown root:root "$2.new"
  mv -f "$2.new" "$2"
}

if [ "$mode" = rollback ]; then
  while IFS= read -r line; do
    path=$(field "$line" 2)
    [ "$(state_of "$path" "$(field "$line" 4)" "$(field "$line" 5)")" = new ] || die 3 "${path#"$root"} is $(short "$(sha "$path")"), not the $(short "$(field "$line" 4)") this installs (see: $0 status); nothing changed"
    [ "$(sha "$path$suffix")" = "$(field "$line" 5)" ] || die 3 "no verified ${path#"$root"}$suffix ($(short "$(field "$line" 5)")); nothing changed"
  done <<< "$files"
  "$systemctl" stop "$unit"
  while IFS= read -r line; do
    path=$(field "$line" 2)
    place "$path$suffix" "$path" "$(field "$line" 6)"
    [ "$(sha "$path")" = "$(field "$line" 5)" ] || die 6 "${path#"$root"} did not verify after the restore; the kept copy is still at ${path#"$root"}$suffix"
  done <<< "$files"
  while IFS= read -r line; do rm -f "$(field "$line" 2)$suffix"; done <<< "$files"
  say "rolled back: owner bc486911, start wrapper df6a1b0b, transport.conf add1bc21"
  restart
  exit 0
fi

# install
[ -n "$OWNER_NEW" ] || die 8 "the new owner's hash is not pinned (OWNER_NEW is empty). Run ./build-owner-idlephase.sh here, report the hash it prints (out/BUILD.txt), have it pinned in install/dev-unit/install-owner-idlephase.sh in the repository, and use that installer; nothing changed"
[ "$(sha "$here/owner-idlephase.sha256")" = "$manifest_sha256" ] || die 5 "owner-idlephase.sha256 is not the list this script pins ($(short "$manifest_sha256")); stage the bundle again; nothing changed"
while read -r want path; do
  [ -n "$want" ] || continue
  [ "$(sha "$here/$path")" = "$want" ] || die 5 "$path in the bundle is not $(short "$want"); stage the bundle again; nothing changed"
done < "$here/owner-idlephase.sha256"
while IFS= read -r line; do
  src=$(field "$line" 3); new=$(field "$line" 4)
  [ -f "$src" ] || die 3 "no ${src#"$here/"}: run ./build-owner-idlephase.sh first; nothing changed"
  [ "$(sha "$src")" = "$new" ] || die 5 "${src#"$here/"} is $(short "$(sha "$src")"), not the pinned $(short "$new") (another build, or another source list); nothing changed"
done <<< "$files"

# The three together: all old (install), all new (already installed), anything else refused.
olds=0 news=0
while IFS= read -r line; do
  path=$(field "$line" 2)
  case "$(state_of "$path" "$(field "$line" 4)" "$(field "$line" 5)")" in
    new) news=$((news + 1)) ;;
    old)
      [ ! -e "$path$suffix" ] || [ "$(sha "$path$suffix")" = "$(field "$line" 5)" ] || die 5 "${path#"$root"}$suffix exists with another hash; nothing changed"
      olds=$((olds + 1)) ;;
    *) die 4 "${path#"$root"} is $(short "$(sha "$path")"), not the $(short "$(field "$line" 5)") this replaces (see: $0 status); nothing changed" ;;
  esac
done <<< "$files"
[ "$news" != 3 ] || { say "already installed"; status; exit 0; }
[ "$olds" = 3 ] || die 4 "$news of the three files are already the new ones and $olds the old: not a state this installs from (see: $0 status); nothing changed"

"$systemctl" stop "$unit"
undo=.idlephase-undo
while IFS= read -r line; do
  path=$(field "$line" 2)
  cp -p "$path" "$path$undo"
done <<< "$files"
fail() {   # put this moment back, start the unit, say why
  while IFS= read -r line; do
    path=$(field "$line" 2); place "$path$undo" "$path" "$(field "$line" 6)"; rm -f "$path$undo" "$path$suffix"
  done <<< "$files"
  restart || true
  die 7 "$1; what was installed before was put back"
}
while IFS= read -r line; do
  path=$(field "$line" 2); mode_bits=$(field "$line" 6)
  [ -e "$path$suffix" ] || install -m "$mode_bits" "$path" "$path$suffix"
  [ -n "$root" ] || chown root:root "$path$suffix"
  place "$(field "$line" 3)" "$path" "$mode_bits"
  [ "$(sha "$path")" = "$(field "$line" 4)" ] || fail "${path#"$root"} did not verify"
done <<< "$files"
while IFS= read -r line; do rm -f "$(field "$line" 2)$undo"; done <<< "$files"
say "installed: owner, start wrapper, transport.conf; what was replaced is kept as *$suffix"
restart
[ "$(active "$unit")" = active ] || die 7 "$unit is not active (journalctl -u $unit -n 40); to go back: sudo $0 rollback"
cat <<EOF
install-owner-idlephase: to accept this (an owner change: the audio path's full battery, at 48 and at 96 kHz):
  1. The START line above: idle_phase_us=60.
  2. From the Mac, at 48 kHz: the noise probe at 32, four loaded 800-impulse runs and the
     ten-minute sixteen-channel soak (dante/measure-candidate.sh); daw_timeline as before.
  3. The same at 96 kHz, with a preset running and opens repeated: no open a block late.
  Anything wrong: sudo $0 rollback (before install-owner-monitor.sh's, if that is ever rolled back)
EOF
