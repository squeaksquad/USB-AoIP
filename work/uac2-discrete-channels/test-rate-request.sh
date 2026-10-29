#!/bin/bash
# test-rate-request.sh: bounded test of the Mac-follow experiment (RATE_REPORT_PLAN.md,
# "Mac-follow experiment"). Loads the experiment u_audio.ko and usb_f_uac2.ko with
# insmod for a window, writes nothing under /lib/modules, and restores the installed
# rate-report pair (u_audio b2f5c6cd, usb_f_uac2 fa8bed12, under updates/usb-16x16/)
# by rmmod and modprobe when the window ends, on Ctrl-C, or when
# /dev/shm/rate-request-test.end appears (any user can create it).
#
#   sudo ./test-rate-request.sh CANDIDATE_DIR [WINDOW_SECONDS]
#
# CANDIDATE_DIR is build/rate-request from build-rate-request.sh. usb16x16-dante stays
# stopped for the whole window, so neither the owner nor the arbiter reacts to the
# rate controls; it is started again after the restore if it was running. In the
# window, as the normal user:
#   amixer -c UAC2Gadget cset iface=PCM,name='Device Rate Request' 44100
# and read the Mac's nominal rate with setrate.swift. The kernel's "rate request:"
# lines (the control write, the interrupt's completion, the host's GET_CUR and
# SET_CUR on the clock) are in dmesg.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 2; fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then echo "usage: $0 CANDIDATE_DIR [WINDOW_SECONDS]" >&2; exit 2; fi

candidate_dir=$1
window_seconds=${2:-600}
kernel_release=$(uname -r)
updates=/lib/modules/$kernel_release/updates/usb-16x16
end_file=/dev/shm/rate-request-test.end
expected_kernel_release=6.18.34+rpt-rpi-2712
expected_candidate_u_audio=0e724e75bb96b0ba0afdb48f14ad0f51b1ba7e14a0a5df63c2095cb1a105e22b
expected_candidate_f_uac2=dd00bcc9bdd846fb03905393ed220fdea38a0fbe52dc653d4ada78f6de093528
expected_candidate_srcversions=D4EA8C97F9638D0B57D14D6/F689FE37BB73173DC75F691
expected_installed_u_audio=b2f5c6cd7c4e25a0d62f6e603ce974b598a269688a3ef79db8c884c7994b4446
expected_installed_f_uac2=fa8bed124e6755695f056a24b448d2fda0027ef1e19fe2fa512533eb3db1f093
expected_installed_srcversions=DD2DD5108A06E3270F336AF/C647475B059D8F6DB983CED
expected_setup_sha256=b11fd3589ff1b554cece30fa1ab89f1dbcb2d98ed86db26c2ab0f5becf58b769
expected_setup_rates_sha256=d4f0ee7bdf8b6268934ee8577c9d0df910379e9beb77ab03a9c36af27fbff70c
candidate_active=0
dante_was_active=0

sha256() { sha256sum "$1" | awk '{print $1}'; }
srcversions() { echo "$(cat /sys/module/u_audio/srcversion 2>/dev/null)/$(cat /sys/module/usb_f_uac2/srcversion 2>/dev/null)"; }
usb_healthy() {
  [ "$(cat /sys/class/udc/*/state 2>/dev/null)" = configured ] &&
    [ "$(cat /sys/class/udc/*/current_speed 2>/dev/null)" = high-speed ]
}
wait_for_usb() {
  for attempt in $(seq 1 "$1"); do usb_healthy && return 0; sleep 1; done
  return 1
}
rates() {
  for n in "Capture Rate" "Playback Rate" "Device Rate Request"; do
    amixer -c UAC2Gadget cget "iface=PCM,name=$n" 2>/dev/null | sed -n 's/^  : values=//p'
  done | paste -sd/
}

if ! [[ "$window_seconds" =~ ^[0-9]+$ ]] || [ "$window_seconds" -lt 60 ] || [ "$window_seconds" -gt 1800 ]; then
  echo "window must be 60..1800 seconds" >&2; exit 3
fi
[ "$kernel_release" = "$expected_kernel_release" ] || { echo "kernel mismatch: $kernel_release" >&2; exit 3; }
[ "$(sha256 "$candidate_dir/u_audio.ko")" = "$expected_candidate_u_audio" ] || { echo "candidate u_audio.ko hash mismatch" >&2; exit 4; }
[ "$(sha256 "$candidate_dir/usb_f_uac2.ko")" = "$expected_candidate_f_uac2" ] || { echo "candidate usb_f_uac2.ko hash mismatch" >&2; exit 4; }
[ "$(sha256 "$updates/u_audio.ko")" = "$expected_installed_u_audio" ] || { echo "installed u_audio.ko is not the rate-report one" >&2; exit 5; }
[ "$(sha256 "$updates/usb_f_uac2.ko")" = "$expected_installed_f_uac2" ] || { echo "installed usb_f_uac2.ko is not the rate-report one" >&2; exit 5; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16)" = "$expected_setup_sha256" ] || { echo "setup-usb-16x16 hash mismatch" >&2; exit 6; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16-rates)" = "$expected_setup_rates_sha256" ] || { echo "setup-usb-16x16-rates hash mismatch" >&2; exit 6; }
[ "$(srcversions)" = "$expected_installed_srcversions" ] || { echo "loaded modules are not the rate-report pair: $(srcversions)" >&2; exit 7; }
if pgrep -x aes67-daemon >/dev/null || pgrep -x alsaloop >/dev/null ||
   pgrep -f '^/usr/local/libexec/usb16x16-rt-bridge([[:space:]]|$)' >/dev/null || lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing while an AES67/audio candidate is active" >&2; exit 8
fi
for unit in usb16x16-apply.service usb16x16-dante-rate.service; do
  systemctl is-active --quiet "$unit" && { echo "refusing while $unit is running" >&2; exit 8; }
done
usb_healthy || { echo "USB is not configured/high-speed before the test" >&2; exit 9; }

swap_out() {
  systemctl stop usb-16x16.service
  /usr/sbin/rmmod usb_f_uac2
  /usr/sbin/rmmod u_audio
}

restore() {
  status=$?
  set +e
  rm -f "$end_file"
  if [ "$candidate_active" -eq 1 ]; then
    echo "restoring the installed modules"
    swap_out
    /usr/sbin/modprobe usb_f_uac2
    systemctl start usb-16x16.service
    wait_for_usb 10 || echo "USB did not return configured/high-speed in 10 s" >&2
    if [ "$dante_was_active" -eq 1 ]; then systemctl start usb16x16-dante; fi
    echo "loaded: $(srcversions) (expected $expected_installed_srcversions)"
    echo "usb state: $(cat /sys/class/udc/*/state) / $(cat /sys/class/udc/*/current_speed); dante: $(systemctl is-active usb16x16-dante); rates $(rates)"
  fi
  exit "$status"
}
trap restore EXIT HUP INT TERM

systemctl is-active --quiet usb16x16-dante && dante_was_active=1
rm -f "$end_file"
echo "before: rates $(rates); loaded $(srcversions)"
candidate_active=1   # from here on, any exit restores the installed modules
systemctl stop usb16x16-dante
swap_out
/usr/sbin/insmod "$candidate_dir/u_audio.ko"
/usr/sbin/insmod "$candidate_dir/usb_f_uac2.ko"
[ "$(srcversions)" = "$expected_candidate_srcversions" ] ||
  { echo "candidate modules did not load: $(srcversions)" >&2; exit 10; }
systemctl start usb-16x16.service
wait_for_usb 10 || { echo "candidate gadget did not enumerate configured/high-speed" >&2; exit 11; }

echo "CANDIDATE READY for $window_seconds s at $(date -u +%T) UTC: rates $(rates); dante $(systemctl is-active usb16x16-dante) (stopped for the window)"
echo "end early: touch $end_file (or Ctrl-C)"
for second in $(seq 1 "$window_seconds"); do
  [ -e "$end_file" ] && { echo "end file seen"; break; }
  sleep 1
done
echo "window over at $(date -u +%T) UTC: rates $(rates)"
