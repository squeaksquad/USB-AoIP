#!/bin/bash
# install-rate-request.sh: the rate-request set (RATE_REPORT_PLAN.md, "Rate request: the
# production set"), persistent, on top of the installed rate-report set.
#
#   sudo ./install-rate-request.sh install    u_audio.ko and usb_f_uac2.ko with the
#                                             Device Rate Request control under
#                                             updates/usb-16x16/, and usb16x16-apply 1.7.0
#                                             (asks the Mac to follow a Dante-side move),
#                                             together
#   sudo ./install-rate-request.sh rollback   the rate-report pair (u_audio b2f5c6cd,
#                                             usb_f_uac2 fa8bed12) and usb16x16-apply 1.6.0
#   ./install-rate-request.sh status          what is on disk and loaded (no root needed)
#
# Run from the staging directory (~/usb-16x16-work/gadget-raterequest/), which holds
# build/rate-request-production/ from `build-rate-request.sh production` and the applier
# copy usb16x16-apply. Every file is checked against a pinned hash first. The installed
# rate-report files are kept beside the installed ones as *.pre-rate-request and a failed
# install puts them back. The pair changes u_audio's export CRCs, so the two modules only
# load together; this rollback comes before install-rate-report.sh rollback, which refuses
# while these modules are installed.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
kernel_release=$(uname -r)
updates=/lib/modules/$kernel_release/updates/usb-16x16
f_uac2_installed=$updates/usb_f_uac2.ko
f_uac2_previous=$updates/usb_f_uac2.ko.pre-rate-request
u_audio_installed=$updates/u_audio.ko
u_audio_previous=$updates/u_audio.ko.pre-rate-request
apply_installed=/usr/local/bin/usb16x16-apply
apply_previous=/usr/local/bin/usb16x16-apply.pre-rate-request
startcheck_status=/run/usb16x16-dante-startcheck/status
candidate=$here/build/rate-request-production

expected_kernel_release=6.18.34+rpt-rpi-2712
new_u_audio=ed539ca898298b3d90863db51808153f83a702f4f330d08bb12753ed7b9baf57
new_f_uac2=505c6ad0bad44f92f5487988d2f192efd9bd7018b7fc60e45e86c90080e20fe2
new_apply=1a85bd3db2490107ef906595cd62b8dc9d38942983bf32c2f7d1a9cebf918b10
new_srcversions=681145C2E4636CAF77983DE/3373101B95DBCD81E04F33F
old_u_audio=b2f5c6cd7c4e25a0d62f6e603ce974b598a269688a3ef79db8c884c7994b4446
old_f_uac2=fa8bed124e6755695f056a24b448d2fda0027ef1e19fe2fa512533eb3db1f093
old_apply=c3c145050d0e06ff2681a986a438208675d1f21bf471d3527e5a1876792f605e
old_srcversions=DD2DD5108A06E3270F336AF/C647475B059D8F6DB983CED
setup_sha256=b11fd3589ff1b554cece30fa1ab89f1dbcb2d98ed86db26c2ab0f5becf58b769
setup_rates_sha256=d4f0ee7bdf8b6268934ee8577c9d0df910379e9beb77ab03a9c36af27fbff70c

sha256() { [ -e "$1" ] && sha256sum "$1" | awk '{print $1}' || echo -; }
short() { echo "$1" | cut -c1-8; }
srcversions() { echo "$(cat /sys/module/u_audio/srcversion 2>/dev/null)/$(cat /sys/module/usb_f_uac2/srcversion 2>/dev/null)"; }
usb_healthy() {
  [ "$(cat /sys/class/udc/*/state 2>/dev/null)" = configured ] &&
    [ "$(cat /sys/class/udc/*/current_speed 2>/dev/null)" = high-speed ] &&
    [ "$(systemctl is-active usb-16x16.service)" = active ]
}
wait_for() {   # wait_for SECONDS COMMAND...
  local seconds=$1; shift
  for attempt in $(seq 1 "$seconds"); do "$@" && return 0; sleep 1; done
  return 1
}
startcheck_ok() {
  local invocation
  invocation=$(systemctl show -p InvocationID --value usb16x16-dante)
  [ -n "$invocation" ] && grep -q "^state=ok .*invocation=$invocation" "$startcheck_status" 2>/dev/null
}
rates() {
  for n in "Capture Rate" "Playback Rate" "Device Rate Request"; do
    amixer -c UAC2Gadget cget "iface=PCM,name=$n" 2>/dev/null | sed -n 's/^  : values=//p'
  done | paste -sd/
}

status() {
  echo "u_audio.ko (updates): $(short "$(sha256 "$u_audio_installed")")  kept: $(short "$(sha256 "$u_audio_previous")")"
  echo "usb_f_uac2.ko: $(short "$(sha256 "$f_uac2_installed")")  kept: $(short "$(sha256 "$f_uac2_previous")")"
  echo "usb16x16-apply: $(short "$(sha256 "$apply_installed")")  kept: $(short "$(sha256 "$apply_previous")")"
  local loaded
  loaded=$(srcversions)
  case "$loaded" in
    "$new_srcversions") echo "loaded: rate-request ($loaded)";;
    "$old_srcversions") echo "loaded: rate-report ($loaded)";;
    *) echo "loaded: other ($loaded)";;
  esac
  echo "usb: $(cat /sys/class/udc/*/state 2>/dev/null)/$(cat /sys/class/udc/*/current_speed 2>/dev/null)  rates: $(rates)  dante: $(systemctl is-active usb16x16-dante)"
}

case "${1:-}" in
  status) status; exit 0;;
  install|rollback) mode=$1;;
  *) echo "usage: $0 install|rollback|status" >&2; exit 2;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 2; }

[ "$kernel_release" = "$expected_kernel_release" ] || { echo "kernel mismatch: $kernel_release" >&2; exit 3; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16)" = "$setup_sha256" ] || { echo "setup-usb-16x16 hash mismatch" >&2; exit 3; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16-rates)" = "$setup_rates_sha256" ] || { echo "setup-usb-16x16-rates hash mismatch" >&2; exit 3; }
if pgrep -x aes67-daemon >/dev/null || pgrep -x alsaloop >/dev/null ||
   pgrep -f '^/usr/local/libexec/usb16x16-rt-bridge([[:space:]]|$)' >/dev/null || lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing while an AES67/audio candidate is active" >&2; exit 4
fi
for unit in usb16x16-apply.service usb16x16-dante-rate.service; do
  case "$(systemctl is-active "$unit")" in
    active|activating|deactivating|reloading) echo "$unit is running an operation; retry when it has finished" >&2; exit 4;;
  esac
done
pgrep -f 'test-rate-(report|request)\.sh' >/dev/null && { echo "a bounded module test is running" >&2; exit 4; }

dante_was_active=0
systemctl is-active --quiet usb16x16-dante && dante_was_active=1

stop_audio() {
  systemctl stop usb16x16-dante
  systemctl stop usb-16x16.service
  /usr/sbin/rmmod usb_f_uac2 2>/dev/null || true
  /usr/sbin/rmmod u_audio 2>/dev/null || true
}
start_audio() {   # start_audio EXPECTED_SRCVERSIONS
  /usr/sbin/modprobe usb_f_uac2
  [ "$(srcversions)" = "$1" ] || { echo "loaded $(srcversions), expected $1" >&2; return 1; }
  systemctl start usb-16x16.service
  wait_for 20 usb_healthy || { echo "USB did not return configured/high-speed in 20 s" >&2; return 1; }
  if [ "$dante_was_active" -eq 1 ]; then
    systemctl start usb16x16-dante
    wait_for 150 startcheck_ok || { echo "the endpoint's start check did not report ok in 150 s" >&2; return 1; }
  fi
}
put_file() {   # put_file SOURCE DESTINATION MODE: temp-and-rename
  install -o root -g root -m "$3" "$1" "$2.new"
  mv -f "$2.new" "$2"
}
to_previous() {   # the rate-report pair and the 1.6.0 applier
  stop_audio
  if [ "$(sha256 "$u_audio_previous")" = "$old_u_audio" ]; then put_file "$u_audio_previous" "$u_audio_installed" 0644; fi
  if [ "$(sha256 "$f_uac2_previous")" = "$old_f_uac2" ]; then put_file "$f_uac2_previous" "$f_uac2_installed" 0644; fi
  /usr/sbin/depmod -a "$kernel_release"
  if [ "$(sha256 "$apply_previous")" = "$old_apply" ]; then put_file "$apply_previous" "$apply_installed" 0755; fi
  [ "$(sha256 "$u_audio_installed")/$(sha256 "$f_uac2_installed")" = "$old_u_audio/$old_f_uac2" ] ||
    { echo "the modules are not the rate-report pair after the restore" >&2; return 1; }
  [ "$(sha256 "$apply_installed")" = "$old_apply" ] || { echo "usb16x16-apply is not 1.6.0 after the restore" >&2; return 1; }
  start_audio "$old_srcversions"
}

if [ "$mode" = rollback ]; then
  for pair in "$u_audio_previous:$old_u_audio" "$f_uac2_previous:$old_f_uac2" "$apply_previous:$old_apply"; do
    [ "$(sha256 "${pair%%:*}")" = "${pair#*:}" ] || { echo "no verified ${pair%%:*}; nothing changed" >&2; exit 5; }
  done
  for triple in "$u_audio_installed:$new_u_audio:$old_u_audio" "$f_uac2_installed:$new_f_uac2:$old_f_uac2" \
                "$apply_installed:$new_apply:$old_apply"; do
    file=${triple%%:*}; rest=${triple#*:}; current=$(sha256 "$file")
    [ "$current" = "${rest%%:*}" ] || [ "$current" = "${rest#*:}" ] ||
      { echo "$file is neither the rate-request nor the rate-report version; nothing changed" >&2; exit 5; }
  done
  to_previous || { echo "rollback did not complete; state:" >&2; status >&2; exit 6; }
  echo "rolled back to the rate-report pair and usb16x16-apply 1.6.0"
  status
  exit 0
fi

# install
[ "$(sha256 "$candidate/u_audio.ko")" = "$new_u_audio" ] || { echo "candidate u_audio.ko hash mismatch" >&2; exit 5; }
[ "$(sha256 "$candidate/usb_f_uac2.ko")" = "$new_f_uac2" ] || { echo "candidate usb_f_uac2.ko hash mismatch" >&2; exit 5; }
[ "$(sha256 "$here/usb16x16-apply")" = "$new_apply" ] || { echo "usb16x16-apply copy is not 1.7.0 $(short "$new_apply")" >&2; exit 5; }
if [ "$(sha256 "$u_audio_installed")" = "$new_u_audio" ] && [ "$(sha256 "$f_uac2_installed")" = "$new_f_uac2" ] &&
   [ "$(sha256 "$apply_installed")" = "$new_apply" ] && [ "$(srcversions)" = "$new_srcversions" ]; then
  usb_healthy || { echo "the rate-request set is installed but USB is not healthy" >&2; exit 6; }
  echo "the rate-request set is already installed"; status; exit 0
fi
[ "$(sha256 "$u_audio_installed")" = "$old_u_audio" ] || { echo "installed u_audio.ko is not the rate-report one; nothing changed" >&2; exit 5; }
[ "$(sha256 "$f_uac2_installed")" = "$old_f_uac2" ] || { echo "installed usb_f_uac2.ko is not the rate-report one; nothing changed" >&2; exit 5; }
[ "$(sha256 "$apply_installed")" = "$old_apply" ] || { echo "installed usb16x16-apply is not 1.6.0 $(short "$old_apply"); nothing changed" >&2; exit 5; }
[ "$(srcversions)" = "$old_srcversions" ] || { echo "loaded modules are not the rate-report pair: $(srcversions)" >&2; exit 5; }
usb_healthy || { echo "USB is not healthy before the install; nothing changed" >&2; exit 5; }
for pair in "$u_audio_previous:$old_u_audio" "$f_uac2_previous:$old_f_uac2" "$apply_previous:$old_apply"; do
  kept=${pair%%:*}
  [ ! -e "$kept" ] || [ "$(sha256 "$kept")" = "${pair#*:}" ] || { echo "$kept exists with another hash; nothing changed" >&2; exit 5; }
done

install_started=0
restore() {
  rc=$?
  set +e
  if [ "$rc" -ne 0 ] && [ "$install_started" -eq 1 ]; then
    echo "install failed; restoring the rate-report pair and usb16x16-apply 1.6.0" >&2
    to_previous || echo "the restore did not complete; check with: $0 status" >&2
    status >&2
  fi
  exit "$rc"
}
trap restore EXIT HUP INT TERM

install -o root -g root -m 0644 "$u_audio_installed" "$u_audio_previous"
install -o root -g root -m 0644 "$f_uac2_installed" "$f_uac2_previous"
install -o root -g root -m 0644 "$apply_installed" "$apply_previous"
install_started=1
stop_audio
put_file "$candidate/u_audio.ko" "$u_audio_installed" 0644
put_file "$candidate/usb_f_uac2.ko" "$f_uac2_installed" 0644
/usr/sbin/depmod -a "$kernel_release"
put_file "$here/usb16x16-apply" "$apply_installed" 0755
[ "$(sha256 "$u_audio_installed")/$(sha256 "$f_uac2_installed")/$(sha256 "$apply_installed")" = "$new_u_audio/$new_f_uac2/$new_apply" ] ||
  { echo "installed files do not match the pinned hashes" >&2; exit 7; }
start_audio "$new_srcversions"

install_started=0
trap - EXIT HUP INT TERM
echo "installed the rate-request set: u_audio $(short "$new_u_audio"), usb_f_uac2 $(short "$new_f_uac2"), usb16x16-apply 1.7.0 $(short "$new_apply")"
echo "kept for rollback: $u_audio_previous, $f_uac2_previous, $apply_previous"
status
