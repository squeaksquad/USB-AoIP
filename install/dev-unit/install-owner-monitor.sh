#!/bin/bash
# install-owner-monitor.sh install|rollback|status
#
# For the development unit (the author's Pi, built by the old installer chain):
# put the phase 3 owner (the monitor block) and the offline runner that knows the
# artifact's monitor section in place of the two the unit runs, and nothing else.
# In the manner of history/installers/dante/service/install-owner-ratepoll.sh:
# every file is checked against a pinned hash and every installed one against the
# hash it is expected to replace; usb16x16-dante.service is stopped for the swap;
# what is replaced is kept beside it as *.pre-monitor; `rollback` puts it back.
#
# What it replaces:
#   /usr/local/libexec/usb16x16-dante/usb16x16-dante-owner   c84e6a36 ("ratepoll", the point of
#                                    record since 2026-11-01) -> OWNER_NEW, built from
#                                    dante/owner/main.cpp at this bundle's source list
#   /usr/local/libexec/usb16x16-dsp-offline                  4492a19c (installed 2026-10-17 by
#                                    install-web-control.sh, the unity-skip core) -> RUNNER_NEW,
#                                    built from dsp-core at the same list
# What it requires and leaves alone: the start wrapper df6a1b0b (installed 2026-11-01 by
# install-dante-rate96-drop96.sh; the new owner's monitor options all have defaults, so the
# wrapper passes none), transport.conf, owner.conf, the plugin, Statime, the units, the page.
#
# The two new hashes are known only once the operator has built the binaries on the unit
# (build-owner-monitor.sh prints them). Until both are pinned below, `install` refuses: an
# install is always of a binary whose hash is on the record.
#
# Order of operations (the operator):
#   1. this, `sudo ./install-owner-monitor.sh install`. The page in place (web 1.8.0, applier
#      1.10.0) never emits a monitor section, so nothing audible changes: the owner writes one
#      monitor status (state=idle) and does nothing else without a monitor-section preset.
#   2. then the page bundle: `sudo ./install-access.sh install` (web 1.9.0, applier 1.11.0, the
#      page with the monitor block), in its own directory.
#   Rollback in the reverse order: `install-access.sh rollback` first, then this `rollback`.
#   This rollback refuses while a preset with a monitor section is the running one (c84e6a36
#   cannot load it): switch to Direct on the page, or re-apply the preset after rolling back
#   the page bundle (the old page compiles it without the section).
#
# Acceptance: this changes the owner, so it is an audio-path change: the full battery (four
# loaded 800-impulse runs and a ten-minute sixteen-channel soak), the last lines say which.
#
#   sudo ./install-owner-monitor.sh install
#   sudo ./install-owner-monitor.sh rollback
#        ./install-owner-monitor.sh status       read-only
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=${USB_AOIP_TEST_ROOT:-}            # tests only: a directory standing in for /
systemctl=${USB_AOIP_TEST_SYSTEMCTL:-systemctl}
journalctl=${USB_AOIP_TEST_JOURNALCTL:-journalctl}
settle=${USB_AOIP_TEST_SETTLE:-12}
suffix=.pre-monitor
unit=usb16x16-dante.service
libexec=$root/usr/local/libexec/usb16x16-dante
owner_path=$libexec/usb16x16-dante-owner
runner_path=$root/usr/local/libexec/usb16x16-dsp-offline
start_path=$libexec/usb16x16-dante-start
owner_conf=$root/etc/usb16x16/dante/owner.conf
# The hash of owner-monitor.sha256, the list of everything the binaries are built from.
# stage-owner-monitor.sh writes it in and checks the list against the repository's.
manifest_sha256=@MANIFEST@

# The new binaries, built on the unit by build-owner-monitor.sh from this list. Empty, and
# install refused, until a build on the unit had given the hashes. Pinned 2026-11-18 from the
# build of 17:24:25 UTC on the author's Pi (list a884de21, g++ Debian 14.2.0-19, cmake 3.31.6);
# a Debian trixie arm64 container with the same compiler gave the same two hashes.
OWNER_NEW=bc48691122f2357606e2cd2a849cde4aee8c0ad6cb7998cad41aaa0c2f320b3e
RUNNER_NEW=46f36659410b612d3ad9da2ae849ec8cfcf40eda672c700c8338af0318cb316a
# What they replace (PROJECT_HANDOFF.md: c84e6a36 the 2026-11-01 point of record; the runner
# 4492a19c, 2026-10-17; the start wrapper df6a1b0b, 2026-11-01).
OWNER_OLD=c84e6a36f41fe439ba729fb2a15fa05e25f72b34c4415cc618e5b5d8048e95c3
RUNNER_OLD=4492a19c0bcfae838cd6bac88fb38867690f88ea9d4ec2b91a9fec50ec467acf
START_WRAPPER=df6a1b0bd22679f8e26050dd4ea9759c18bf598bdac3c771eafcc5f7f1c6b495

say()   { echo "install-owner-monitor: $*"; }
die()   { echo "install-owner-monitor: $2" >&2; exit "$1"; }
sha()   { if [ ! -f "$1" ]; then echo -; elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
short() { echo "$1" | cut -c1-8; }

# Hashes the tests stand in for (a test cannot make a file that hashes to c84e6a36). Taken only
# with a stand-in root: on the unit the pins above are the only ones.
for var in OWNER_NEW RUNNER_NEW OWNER_OLD RUNNER_OLD; do
  test_var=USB_AOIP_TEST_$var
  [ -n "${!test_var:-}" ] || continue
  [ -n "$root" ] || die 2 "$test_var is for the tests and is taken only with USB_AOIP_TEST_ROOT; unset it"
  # EMPTY stands for a pin not yet made, so the refusal for one stays tested once the pins are in.
  if [ "${!test_var}" = EMPTY ]; then printf -v "$var" '%s' ''; else printf -v "$var" '%s' "${!test_var}"; fi
done

# name | installed path | the bundle's file | new | old
files="owner|$owner_path|$here/out/usb16x16-dante-owner|$OWNER_NEW|$OWNER_OLD
runner|$runner_path|$here/out/usb16x16-dsp-offline|$RUNNER_NEW|$RUNNER_OLD"
field() { echo "$1" | cut -d'|' -f"$2"; }
state_of() {   # new | old | other (short hash) | absent
  local now; now=$(sha "$1")
  if [ "$now" = - ]; then echo absent
  elif [ -n "$2" ] && [ "$now" = "$2" ]; then echo new
  elif [ "$now" = "$3" ]; then echo old
  else echo "other ($(short "$now"))"; fi
}
active() { "$systemctl" is-active "$1" 2>/dev/null || true; }

# The preset the owner runs, and its artifacts at the other rates (the arbiter can move the
# owner onto one of those): any with a monitor section is one c84e6a36 cannot load. The
# loader's own test is the word `monitor` where `end` is expected; the compiler writes the
# line `monitor 1`. A looser match than that refuses more, never less.
monitor_presets() {
  local preset base f
  preset=$(sed -n 's/^DSP_PRESET=//p' "$owner_conf" 2>/dev/null | tail -1)
  [ -n "$preset" ] || return 0
  base=${preset%.dsp}; base=${base%@*}
  for f in "$root$base.dsp" "$root$base"@*.dsp; do
    [ -f "$f" ] || continue
    grep -Eq '^[[:space:]]*monitor([[:space:]]|$)' "$f" && echo "${f#"$root"}"
  done
  return 0
}

status() {
  local line path
  echo "  binary pins: owner $( [ -n "$OWNER_NEW" ] && short "$OWNER_NEW" || echo EMPTY ), runner $( [ -n "$RUNNER_NEW" ] && short "$RUNNER_NEW" || echo EMPTY )"
  while IFS= read -r line; do
    path=$(field "$line" 2)
    printf '  %-52s %-16s kept: %s   bundle out/: %s\n' "${path#"$root"}" "$(state_of "$path" "$(field "$line" 4)" "$(field "$line" 5)")" \
      "$(short "$(sha "$path$suffix")")" "$(short "$(sha "$(field "$line" 3)")")"
  done <<< "$files"
  printf '  %-52s %s\n' "${start_path#"$root"}" "$( [ "$(sha "$start_path")" = "$START_WRAPPER" ] && echo "df6a1b0b (expected)" || echo "NOT df6a1b0b ($(short "$(sha "$start_path")"))")"
  local running; running=$(monitor_presets | tr '\n' ' '); running=${running% }
  echo "  running preset: $(sed -n 's/^DSP_PRESET=//p' "$owner_conf" 2>/dev/null | tail -1 | grep . || echo 'none (direct)')${running:+; WITH a monitor section: $running}"
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

# The start wrapper this owner was built to be started by; nothing else is checked for it.
[ "$(sha "$start_path")" = "$START_WRAPPER" ] || die 4 "${start_path#"$root"} is $(short "$(sha "$start_path")"), not the $(short "$START_WRAPPER") this expects; nothing changed"
[ "$(active usb16x16-dante-candidate.service)" != active ] || die 4 "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop); nothing changed"
for u in usb16x16-dante-rate.service usb16x16-apply.service; do
  case "$(active "$u")" in
    active|activating|deactivating|reloading) die 4 "$u is running an operation; try again when it has finished; nothing changed" ;;
  esac
done

restart() {
  local since; since=$(date +%s)
  "$systemctl" reset-failed "$unit" 2>/dev/null || true
  "$systemctl" start "$unit"
  sleep "$settle"
  echo "  $unit is $(active "$unit")"
  echo "  owner $(short "$(sha "$owner_path")"), runner $(short "$(sha "$runner_path")"), start wrapper $(short "$(sha "$start_path")")"
  echo "  the owner's first MONITOR lines:"
  "$journalctl" -u "$unit" --since "@$since" --no-pager -o cat 2>/dev/null | grep '^MONITOR' | head -4 | sed 's/^/    /' || true
}
place() {   # place SOURCE DESTINATION: a temporary file and a rename
  install -m 755 "$1" "$2.new"
  [ -n "$root" ] || chown root:root "$2.new"
  mv -f "$2.new" "$2"
}

if [ "$mode" = rollback ]; then
  while IFS= read -r line; do
    path=$(field "$line" 2); old=$(field "$line" 5)
    [ "$(sha "$path$suffix")" = "$old" ] || die 3 "no verified ${path#"$root"}$suffix ($(short "$old")); nothing changed"
  done <<< "$files"
  running=$(monitor_presets | tr '\n' ' '); running=${running% }
  [ -z "$running" ] || die 4 "the running preset has a monitor section ($running), which c84e6a36 cannot load: the unit would restart onto nothing. Switch to Direct on the page, or roll back the page bundle first (install-access.sh rollback) and apply the preset again from the old page, which compiles it without the section; nothing changed"
  "$systemctl" stop "$unit"
  while IFS= read -r line; do
    path=$(field "$line" 2)
    place "$path$suffix" "$path"
    [ "$(sha "$path")" = "$(field "$line" 5)" ] || die 6 "${path#"$root"} did not verify after the restore; the kept copy is still at ${path#"$root"}$suffix"
  done <<< "$files"
  while IFS= read -r line; do rm -f "$(field "$line" 2)$suffix"; done <<< "$files"
  say "rolled back: owner c84e6a36 and runner 4492a19c"
  restart
  exit 0
fi

# install
[ -n "$OWNER_NEW" ] && [ -n "$RUNNER_NEW" ] || die 8 "the new binaries' hashes are not pinned yet (OWNER_NEW, RUNNER_NEW are empty). Run ./build-owner-monitor.sh here, report the two hashes it prints (out/BUILD.txt), have them pinned in install/dev-unit/install-owner-monitor.sh in the repository, and use that installer; nothing changed"
[ "$(sha "$here/owner-monitor.sha256")" = "$manifest_sha256" ] || die 5 "owner-monitor.sha256 is not the list this script pins ($(short "$manifest_sha256")); stage the bundle again; nothing changed"
while read -r want path; do
  [ -n "$want" ] || continue
  [ "$(sha "$here/$path")" = "$want" ] || die 5 "$path in the bundle is not $(short "$want"); stage the bundle again; nothing changed"
done < "$here/owner-monitor.sha256"
while IFS= read -r line; do
  src=$(field "$line" 3); new=$(field "$line" 4)
  [ -f "$src" ] || die 3 "no ${src#"$here/"}: run ./build-owner-monitor.sh first; nothing changed"
  [ "$(sha "$src")" = "$new" ] || die 5 "${src#"$here/"} is $(short "$(sha "$src")"), not the pinned $(short "$new") (another build, or another source list); nothing changed"
done <<< "$files"

change=""
while IFS= read -r line; do
  name=$(field "$line" 1); path=$(field "$line" 2)
  case "$(state_of "$path" "$(field "$line" 4)" "$(field "$line" 5)")" in
    new) ;;
    old)
      [ ! -e "$path$suffix" ] || [ "$(sha "$path$suffix")" = "$(field "$line" 5)" ] || die 5 "${path#"$root"}$suffix exists with another hash; nothing changed"
      change="$change $name" ;;
    *) die 4 "${path#"$root"} is $(short "$(sha "$path")"), not the $(short "$(field "$line" 5)") this replaces (see: $0 status); nothing changed" ;;
  esac
done <<< "$files"
[ -n "$change" ] || { say "already installed"; status; exit 0; }

"$systemctl" stop "$unit"
undo=.monitor-undo
while IFS= read -r line; do
  path=$(field "$line" 2)
  cp -p "$path" "$path$undo"
done <<< "$files"
fail() {   # put this moment back, start the unit, say why
  while IFS= read -r line; do
    path=$(field "$line" 2); place "$path$undo" "$path"; rm -f "$path$undo"
    [[ " $change " == *" $(field "$line" 1) "* ]] && rm -f "$path$suffix"
  done <<< "$files"
  restart || true
  die 7 "$1; what was installed before was put back"
}
while IFS= read -r line; do
  name=$(field "$line" 1); path=$(field "$line" 2)
  [[ " $change " == *" $name "* ]] || continue
  [ -e "$path$suffix" ] || install -m 755 "$path" "$path$suffix"
  [ -n "$root" ] || chown root:root "$path$suffix"
  place "$(field "$line" 3)" "$path"
  [ "$(sha "$path")" = "$(field "$line" 4)" ] || fail "${path#"$root"} did not verify"
done <<< "$files"
while IFS= read -r line; do rm -f "$(field "$line" 2)$undo"; done <<< "$files"
say "installed:$change; what was replaced is kept as *$suffix"
restart
[ "$(active "$unit")" = active ] || die 7 "$unit is not active (journalctl -u $unit -n 40); to go back: sudo $0 rollback"
cat <<EOF
install-owner-monitor: to accept this (an owner change: the audio path's full battery):
  1. The MONITOR lines above: "MONITOR following ..." and "MONITOR first state=idle" while no
     preset with a monitor section runs; /run/usb16x16-dante/monitor.status exists.
  2. On the page (still the old one): Apply a preset and back to Direct (the runner's load check).
  3. From the Mac: the noise probe at 32, four loaded 800-impulse runs and the ten-minute
     sixteen-channel soak (dante/measure-candidate.sh); daw_timeline as before (528 at 48 kHz).
  4. Then the page bundle: sudo ./install-access.sh install, in its own directory.
  Anything wrong: sudo $0 rollback
EOF
