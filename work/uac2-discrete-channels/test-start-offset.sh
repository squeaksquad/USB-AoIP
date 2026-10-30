#!/bin/bash
# test-start-offset.sh: bounded test of the Playback Start Offset modules
# (work/mac-driver-spike/SPIKE_PLAN.md, "Phase C", step 2). Loads build/start-offset's
# u_audio.ko and usb_f_uac2.ko with insmod for a window, writes nothing under
# /lib/modules, and restores the installed rate-request pair (u_audio ed539ca8,
# usb_f_uac2 505c6ad0, under updates/usb-16x16/) by rmmod and modprobe when the window
# ends, on Ctrl-C, or when /dev/shm/start-offset-test.end appears (any user can create it).
#
#   sudo ./test-start-offset.sh [WINDOW_SECONDS]
#
# usb16x16-dante is stopped for the whole window, so a candidate owner can be run in it
# through /usr/local/sbin/usb16x16-dante-candidate; the candidate unit is stopped and
# usb16x16-dante started again after the restore if it was running. Through the window
# the control is read ten times a second and every change is printed with its UTC time
# (also to /dev/shm/start-offset-test.log, readable by any user):
#   generation in_start in_now out_missed in_failed out_unread out_unreported out_dropped
# in_start / in_now read -2147483648 until a ring packet has reached the host; out_unread /
# out_unreported (capture frames written before OUT alt 1 that the application had not read,
# and of those not yet in ALSA's hw_ptr) read -2147483648 if capture was not running.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 2; fi
if [ "$#" -gt 1 ]; then echo "usage: $0 [WINDOW_SECONDS]" >&2; exit 2; fi

here=$(cd "$(dirname "$0")" && pwd)
candidate_dir=$here/build/start-offset
window_seconds=${1:-900}
kernel_release=$(uname -r)
updates=/lib/modules/$kernel_release/updates/usb-16x16
end_file=/dev/shm/start-offset-test.end
log=/dev/shm/start-offset-test.log
expected_kernel_release=6.18.34+rpt-rpi-2712
expected_candidate_u_audio=280c8c96abcd470ed8d6f7f5014e0beea783d35def01efcaad207e7f7473bf6f
expected_candidate_f_uac2=505c6ad0bad44f92f5487988d2f192efd9bd7018b7fc60e45e86c90080e20fe2
expected_candidate_srcversions=B8D71924ED2F102086D0BCE/3373101B95DBCD81E04F33F
expected_installed_u_audio=ed539ca898298b3d90863db51808153f83a702f4f330d08bb12753ed7b9baf57
expected_installed_f_uac2=505c6ad0bad44f92f5487988d2f192efd9bd7018b7fc60e45e86c90080e20fe2
expected_installed_srcversions=681145C2E4636CAF77983DE/3373101B95DBCD81E04F33F
expected_setup_sha256=b11fd3589ff1b554cece30fa1ab89f1dbcb2d98ed86db26c2ab0f5becf58b769
expected_setup_aoip_sha256=65d26567a29fa22c4d61c79c155004c9faaff99012ae492368d39a998995d585
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
start_offset() {
  amixer -c UAC2Gadget cget "iface=PCM,name=Playback Start Offset" 2>/dev/null | sed -n 's/^  : values=//p' | tr , ' '
}

if ! [[ "$window_seconds" =~ ^[0-9]+$ ]] || [ "$window_seconds" -lt 60 ] || [ "$window_seconds" -gt 1800 ]; then
  echo "window must be 60..1800 seconds" >&2; exit 3
fi
[ "$kernel_release" = "$expected_kernel_release" ] || { echo "kernel mismatch: $kernel_release" >&2; exit 3; }
[ "$(sha256 "$candidate_dir/u_audio.ko")" = "$expected_candidate_u_audio" ] || { echo "candidate u_audio.ko hash mismatch" >&2; exit 4; }
[ "$(sha256 "$candidate_dir/usb_f_uac2.ko")" = "$expected_candidate_f_uac2" ] || { echo "candidate usb_f_uac2.ko hash mismatch" >&2; exit 4; }
[ "$(sha256 "$updates/u_audio.ko")" = "$expected_installed_u_audio" ] || { echo "installed u_audio.ko is not the rate-request one" >&2; exit 5; }
[ "$(sha256 "$updates/usb_f_uac2.ko")" = "$expected_installed_f_uac2" ] || { echo "installed usb_f_uac2.ko is not the rate-request one" >&2; exit 5; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16)" = "$expected_setup_sha256" ] || { echo "setup-usb-16x16 hash mismatch" >&2; exit 6; }
[ "$(sha256 /usr/local/sbin/setup-usb-aoip)" = "$expected_setup_aoip_sha256" ] || { echo "setup-usb-aoip hash mismatch" >&2; exit 6; }
[ "$(srcversions)" = "$expected_installed_srcversions" ] || { echo "loaded modules are not the rate-request pair: $(srcversions)" >&2; exit 7; }
if pgrep -x aes67-daemon >/dev/null || pgrep -x alsaloop >/dev/null ||
   pgrep -f '^/usr/local/libexec/usb16x16-rt-bridge([[:space:]]|$)' >/dev/null || lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing while an AES67/audio candidate is active" >&2; exit 8
fi
for unit in usb16x16-apply.service usb16x16-dante-rate.service usb16x16-dante-candidate.service; do
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
    systemctl stop usb16x16-dante-candidate 2>/dev/null
    systemctl stop usb16x16-dante
    swap_out
    /usr/sbin/modprobe usb_f_uac2
    systemctl start usb-16x16.service
    wait_for_usb 10 || echo "USB did not return configured/high-speed in 10 s" >&2
    if [ "$dante_was_active" -eq 1 ]; then systemctl start usb16x16-dante; fi
    echo "loaded: $(srcversions) (expected $expected_installed_srcversions)"
    echo "usb state: $(cat /sys/class/udc/*/state) / $(cat /sys/class/udc/*/current_speed); dante: $(systemctl is-active usb16x16-dante)"
  fi
  exit "$status"
}
trap restore EXIT HUP INT TERM

systemctl is-active --quiet usb16x16-dante && dante_was_active=1
rm -f "$end_file"
: > "$log"; chmod 644 "$log"
echo "before: loaded $(srcversions)"
candidate_active=1   # from here on, any exit restores the installed modules
systemctl stop usb16x16-dante
swap_out
/usr/sbin/insmod "$candidate_dir/u_audio.ko"
/usr/sbin/insmod "$candidate_dir/usb_f_uac2.ko"
[ "$(srcversions)" = "$expected_candidate_srcversions" ] ||
  { echo "candidate modules did not load: $(srcversions)" >&2; exit 10; }
systemctl start usb-16x16.service
wait_for_usb 10 || { echo "candidate gadget did not enumerate configured/high-speed" >&2; exit 11; }

echo "CANDIDATE READY for $window_seconds s at $(date -u +%T) UTC: start offset $(start_offset); dante $(systemctl is-active usb16x16-dante)"
echo "end early: touch $end_file (or Ctrl-C)"
last=
for tick in $(seq 1 $((window_seconds * 10))); do
  [ -e "$end_file" ] && { echo "end file seen"; break; }
  now=$(start_offset)
  if [ "$now" != "$last" ]; then
    echo "SO wall=$(date -u +%s.%N | cut -c1-14) $now" | tee -a "$log"
    last=$now
  fi
  sleep 0.1
done
echo "window over at $(date -u +%T) UTC"
