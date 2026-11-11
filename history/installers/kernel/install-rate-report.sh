#!/bin/bash
# install-rate-report.sh: the rate-report set (RATE_REPORT_PLAN.md, step 5), persistent.
#
#   sudo ./install-rate-report.sh install    the patched u_audio.ko and usb_f_uac2.ko under
#                                            updates/usb-16x16/, and usb16x16-apply 1.6.0
#                                            (the arbiter guard), together
#   sudo ./install-rate-report.sh rollback   the stock u_audio, the label usb_f_uac2
#                                            (87989337) and usb16x16-apply 1.5.0 (4a4aef82)
#   ./install-rate-report.sh status          what is on disk and loaded (no root needed)
#
# Run from the staging directory (~/usb-16x16-work/gadget-ratereport/), which holds
# build/rate-report/ from build-rate-report.sh and the applier copy usb16x16-apply.
# Every file is checked against a pinned hash first. The stock u_audio.ko.xz under
# kernel/ is never written: the patched one goes under updates/, which modprobe
# prefers, and rollback removes it. The label module and the 1.5.0 applier are kept
# beside the installed files as *.pre-rate-report. A failed install puts all of it
# back. The modules go together: the label or baseline usb_f_uac2 loads against the
# patched u_audio but never forgets the rate at a disconnect, so this rollback comes
# before any older module rollback (usb_f_uac2.ko.pre-discrete-channels).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
kernel_release=$(uname -r)
updates=/lib/modules/$kernel_release/updates/usb-16x16
f_uac2_installed=$updates/usb_f_uac2.ko
f_uac2_previous=$updates/usb_f_uac2.ko.pre-rate-report
u_audio_installed=$updates/u_audio.ko
stock_u_audio=/lib/modules/$kernel_release/kernel/drivers/usb/gadget/function/u_audio.ko.xz
apply_installed=/usr/local/bin/usb16x16-apply
apply_previous=/usr/local/bin/usb16x16-apply.pre-rate-report
startcheck_status=/run/usb16x16-dante-startcheck/status

expected_kernel_release=6.18.34+rpt-rpi-2712
new_u_audio=b2f5c6cd7c4e25a0d62f6e603ce974b598a269688a3ef79db8c884c7994b4446
new_f_uac2=fa8bed124e6755695f056a24b448d2fda0027ef1e19fe2fa512533eb3db1f093
new_apply=c3c145050d0e06ff2681a986a438208675d1f21bf471d3527e5a1876792f605e
new_srcversions=DD2DD5108A06E3270F336AF/C647475B059D8F6DB983CED
old_f_uac2=87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e
old_apply=4a4aef8233a8bd07ba9cd606f575455042915a9c9a5f09a78a292fdfa296bffe
old_srcversions=0F2DD68CE58B97752054D11/E40AF44844557D3989AFC4C
stock_u_audio_sha256=dde02c49a3f843b2404e762a969a8d145e36d6e2d16a0f341553571b7b2fc9b6
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
  for n in "Capture Rate" "Playback Rate"; do
    amixer -c UAC2Gadget cget "iface=PCM,name=$n" 2>/dev/null | sed -n 's/^  : values=//p'
  done | paste -sd/
}

status() {
  echo "u_audio.ko (updates): $(short "$(sha256 "$u_audio_installed")")  usb_f_uac2.ko: $(short "$(sha256 "$f_uac2_installed")")  kept: $(short "$(sha256 "$f_uac2_previous")")"
  echo "usb16x16-apply: $(short "$(sha256 "$apply_installed")")  kept: $(short "$(sha256 "$apply_previous")")"
  local loaded
  loaded=$(srcversions)
  case "$loaded" in
    "$new_srcversions") echo "loaded: rate-report ($loaded)";;
    "$old_srcversions") echo "loaded: stock u_audio + label usb_f_uac2 ($loaded)";;
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
[ "$(sha256 "$stock_u_audio")" = "$stock_u_audio_sha256" ] || { echo "stock u_audio.ko.xz hash mismatch" >&2; exit 3; }
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
pgrep -f 'test-rate-report\.sh' >/dev/null && { echo "test-rate-report.sh is running" >&2; exit 4; }

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
to_previous() {   # the label module, the stock u_audio and the 1.5.0 applier
  stop_audio
  rm -f "$u_audio_installed"
  if [ "$(sha256 "$f_uac2_previous")" = "$old_f_uac2" ]; then
    put_file "$f_uac2_previous" "$f_uac2_installed" 0644
  fi
  /usr/sbin/depmod -a "$kernel_release"
  if [ "$(sha256 "$apply_previous")" = "$old_apply" ]; then
    put_file "$apply_previous" "$apply_installed" 0755
  fi
  [ "$(sha256 "$f_uac2_installed")" = "$old_f_uac2" ] || { echo "usb_f_uac2.ko is not the label module after the restore" >&2; return 1; }
  [ "$(sha256 "$apply_installed")" = "$old_apply" ] || { echo "usb16x16-apply is not 1.5.0 after the restore" >&2; return 1; }
  start_audio "$old_srcversions"
}

if [ "$mode" = rollback ]; then
  [ "$(sha256 "$f_uac2_previous")" = "$old_f_uac2" ] || { echo "no verified $f_uac2_previous; nothing changed" >&2; exit 5; }
  [ "$(sha256 "$apply_previous")" = "$old_apply" ] || { echo "no verified $apply_previous; nothing changed" >&2; exit 5; }
  current=$(sha256 "$f_uac2_installed")
  [ "$current" = "$new_f_uac2" ] || [ "$current" = "$old_f_uac2" ] ||
    { echo "usb_f_uac2.ko is neither the rate-report nor the label module; nothing changed" >&2; exit 5; }
  current=$(sha256 "$apply_installed")
  [ "$current" = "$new_apply" ] || [ "$current" = "$old_apply" ] ||
    { echo "usb16x16-apply is neither 1.6.0 nor 1.5.0; nothing changed" >&2; exit 5; }
  to_previous || { echo "rollback did not complete; state:" >&2; status >&2; exit 6; }
  echo "rolled back to the stock u_audio, the label usb_f_uac2 and usb16x16-apply 1.5.0"
  status
  exit 0
fi

# install
[ "$(sha256 "$here/build/rate-report/u_audio.ko")" = "$new_u_audio" ] || { echo "candidate u_audio.ko hash mismatch" >&2; exit 5; }
[ "$(sha256 "$here/build/rate-report/usb_f_uac2.ko")" = "$new_f_uac2" ] || { echo "candidate usb_f_uac2.ko hash mismatch" >&2; exit 5; }
[ "$(sha256 "$here/usb16x16-apply")" = "$new_apply" ] || { echo "usb16x16-apply copy is not 1.6.0 $(short "$new_apply")" >&2; exit 5; }
if [ "$(sha256 "$u_audio_installed")" = "$new_u_audio" ] && [ "$(sha256 "$f_uac2_installed")" = "$new_f_uac2" ] &&
   [ "$(sha256 "$apply_installed")" = "$new_apply" ] && [ "$(srcversions)" = "$new_srcversions" ]; then
  usb_healthy || { echo "the rate-report set is installed but USB is not healthy" >&2; exit 6; }
  echo "the rate-report set is already installed"; status; exit 0
fi
[ "$(sha256 "$f_uac2_installed")" = "$old_f_uac2" ] || { echo "installed usb_f_uac2.ko is not the label module; nothing changed" >&2; exit 5; }
[ ! -e "$u_audio_installed" ] || { echo "$u_audio_installed exists already; nothing changed" >&2; exit 5; }
[ "$(sha256 "$apply_installed")" = "$old_apply" ] || { echo "installed usb16x16-apply is not 1.5.0 $(short "$old_apply"); nothing changed" >&2; exit 5; }
[ "$(srcversions)" = "$old_srcversions" ] || { echo "loaded modules are not stock u_audio + label usb_f_uac2: $(srcversions)" >&2; exit 5; }
usb_healthy || { echo "USB is not healthy before the install; nothing changed" >&2; exit 5; }
for pair in "$f_uac2_previous:$old_f_uac2" "$apply_previous:$old_apply"; do
  kept=${pair%%:*}
  [ ! -e "$kept" ] || [ "$(sha256 "$kept")" = "${pair#*:}" ] || { echo "$kept exists with another hash; nothing changed" >&2; exit 5; }
done

install_started=0
restore() {
  rc=$?
  set +e
  if [ "$rc" -ne 0 ] && [ "$install_started" -eq 1 ]; then
    echo "install failed; restoring the label module, the stock u_audio and usb16x16-apply 1.5.0" >&2
    to_previous || echo "the restore did not complete; check with: $0 status" >&2
    status >&2
  fi
  exit "$rc"
}
trap restore EXIT HUP INT TERM

install -o root -g root -m 0644 "$f_uac2_installed" "$f_uac2_previous"
install -o root -g root -m 0644 "$apply_installed" "$apply_previous"
install_started=1
stop_audio
put_file "$here/build/rate-report/u_audio.ko" "$u_audio_installed" 0644
put_file "$here/build/rate-report/usb_f_uac2.ko" "$f_uac2_installed" 0644
/usr/sbin/depmod -a "$kernel_release"
put_file "$here/usb16x16-apply" "$apply_installed" 0755
[ "$(sha256 "$u_audio_installed")/$(sha256 "$f_uac2_installed")/$(sha256 "$apply_installed")" = "$new_u_audio/$new_f_uac2/$new_apply" ] ||
  { echo "installed files do not match the pinned hashes" >&2; exit 7; }
start_audio "$new_srcversions"

install_started=0
trap - EXIT HUP INT TERM
echo "installed the rate-report set: u_audio $(short "$new_u_audio"), usb_f_uac2 $(short "$new_f_uac2"), usb16x16-apply 1.6.0 $(short "$new_apply")"
echo "kept for rollback: $f_uac2_previous, $apply_previous"
status
