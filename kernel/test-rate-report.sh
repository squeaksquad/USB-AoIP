#!/bin/bash
# test-rate-report.sh: bounded first contact with the rate-report modules
# (RATE_REPORT_PLAN.md, step 5). Loads the candidate u_audio.ko and usb_f_uac2.ko with
# insmod for a window, writes nothing under /lib/modules, and restores the installed
# modules (label usb_f_uac2 87989337, stock u_audio) by rmmod and modprobe when the
# window ends, on Ctrl-C, or when /dev/shm/rate-report-test.end appears (any user can
# create it). usb16x16-dante is stopped for each module swap and started again after
# it if it was running.
#
#   sudo ./test-rate-report.sh CANDIDATE_DIR [WINDOW_SECONDS]
#
# CANDIDATE_DIR is build/rate-report from build-rate-report.sh. During the window
# read the controls with `amixer -c UAC2Gadget cget iface=PCM,name='Capture Rate'`.
# The arbiter guard is not part of this test: make no Dante-side rate set in the window.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 2; fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then echo "usage: $0 CANDIDATE_DIR [WINDOW_SECONDS]" >&2; exit 2; fi

candidate_dir=$1
window_seconds=${2:-600}
kernel_release=$(uname -r)
label_module=/lib/modules/$kernel_release/updates/usb-16x16/usb_f_uac2.ko
stock_u_audio=/lib/modules/$kernel_release/kernel/drivers/usb/gadget/function/u_audio.ko.xz
end_file=/dev/shm/rate-report-test.end
expected_kernel_release=6.18.34+rpt-rpi-2712
expected_candidate_u_audio=b2f5c6cd7c4e25a0d62f6e603ce974b598a269688a3ef79db8c884c7994b4446
expected_candidate_f_uac2=fa8bed124e6755695f056a24b448d2fda0027ef1e19fe2fa512533eb3db1f093
expected_candidate_u_audio_srcversion=DD2DD5108A06E3270F336AF
expected_candidate_f_uac2_srcversion=C647475B059D8F6DB983CED
expected_label_sha256=87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e
expected_label_srcversion=E40AF44844557D3989AFC4C
expected_stock_u_audio_sha256=dde02c49a3f843b2404e762a969a8d145e36d6e2d16a0f341553571b7b2fc9b6
expected_stock_u_audio_srcversion=0F2DD68CE58B97752054D11
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
  for n in "Capture Rate" "Playback Rate"; do
    amixer -c UAC2Gadget cget "iface=PCM,name=$n" 2>/dev/null | sed -n 's/^  : values=//p'
  done | paste -sd/
}

if ! [[ "$window_seconds" =~ ^[0-9]+$ ]] || [ "$window_seconds" -lt 60 ] || [ "$window_seconds" -gt 1800 ]; then
  echo "window must be 60..1800 seconds" >&2; exit 3
fi
[ "$kernel_release" = "$expected_kernel_release" ] || { echo "kernel mismatch: $kernel_release" >&2; exit 3; }
[ "$(sha256 "$candidate_dir/u_audio.ko")" = "$expected_candidate_u_audio" ] || { echo "candidate u_audio.ko hash mismatch" >&2; exit 4; }
[ "$(sha256 "$candidate_dir/usb_f_uac2.ko")" = "$expected_candidate_f_uac2" ] || { echo "candidate usb_f_uac2.ko hash mismatch" >&2; exit 4; }
[ "$(sha256 "$label_module")" = "$expected_label_sha256" ] || { echo "installed usb_f_uac2.ko is not the label module" >&2; exit 5; }
[ "$(sha256 "$stock_u_audio")" = "$expected_stock_u_audio_sha256" ] || { echo "stock u_audio.ko.xz hash mismatch" >&2; exit 5; }
[ ! -e "/lib/modules/$kernel_release/updates/usb-16x16/u_audio.ko" ] || { echo "an u_audio.ko is installed under updates/; this test is for the stock one" >&2; exit 5; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16)" = "$expected_setup_sha256" ] || { echo "setup-usb-16x16 hash mismatch" >&2; exit 6; }
[ "$(sha256 /usr/local/sbin/setup-usb-16x16-rates)" = "$expected_setup_rates_sha256" ] || { echo "setup-usb-16x16-rates hash mismatch" >&2; exit 6; }
[ "$(srcversions)" = "$expected_stock_u_audio_srcversion/$expected_label_srcversion" ] || { echo "loaded modules are not stock u_audio + label usb_f_uac2: $(srcversions)" >&2; exit 7; }
if pgrep -x aes67-daemon >/dev/null || pgrep -x alsaloop >/dev/null ||
   pgrep -f '^/usr/local/libexec/usb16x16-rt-bridge([[:space:]]|$)' >/dev/null || lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing while an AES67/audio candidate is active" >&2; exit 8
fi
usb_healthy || { echo "USB is not configured/high-speed before the test" >&2; exit 9; }

stop_audio() {
  systemctl stop usb16x16-dante
  systemctl stop usb-16x16.service
  /usr/sbin/rmmod usb_f_uac2
  /usr/sbin/rmmod u_audio
}
start_audio() {
  systemctl start usb-16x16.service
  wait_for_usb 10 || return 1
  if [ "$dante_was_active" -eq 1 ]; then systemctl start usb16x16-dante; fi
}

restore() {
  status=$?
  set +e
  rm -f "$end_file"
  if [ "$candidate_active" -eq 1 ]; then
    echo "restoring the installed modules"
    systemctl stop usb16x16-dante
    systemctl stop usb-16x16.service
    /usr/sbin/rmmod usb_f_uac2
    /usr/sbin/rmmod u_audio
    /usr/sbin/modprobe usb_f_uac2
    start_audio || echo "USB did not return configured/high-speed in 10 s" >&2
    echo "loaded: $(srcversions) (expected $expected_stock_u_audio_srcversion/$expected_label_srcversion)"
    echo "usb state: $(cat /sys/class/udc/*/state) / $(cat /sys/class/udc/*/current_speed); dante: $(systemctl is-active usb16x16-dante)"
  fi
  exit "$status"
}
trap restore EXIT HUP INT TERM

systemctl is-active --quiet usb16x16-dante && dante_was_active=1
rm -f "$end_file"
echo "before: rates $(rates); loaded $(srcversions)"
candidate_active=1   # from here on, any exit restores the installed modules
stop_audio
/usr/sbin/insmod "$candidate_dir/u_audio.ko"
/usr/sbin/insmod "$candidate_dir/usb_f_uac2.ko"
[ "$(srcversions)" = "$expected_candidate_u_audio_srcversion/$expected_candidate_f_uac2_srcversion" ] ||
  { echo "candidate modules did not load: $(srcversions)" >&2; exit 10; }
start_audio || { echo "candidate gadget did not enumerate configured/high-speed" >&2; exit 11; }

echo "CANDIDATE READY for $window_seconds s at $(date -u +%T) UTC: rates $(rates); dante $(systemctl is-active usb16x16-dante)"
echo "end early: touch $end_file (or Ctrl-C)"
for second in $(seq 1 "$window_seconds"); do
  [ -e "$end_file" ] && { echo "end file seen"; break; }
  sleep 1
done
echo "window over at $(date -u +%T) UTC: rates $(rates)"
