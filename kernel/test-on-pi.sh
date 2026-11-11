#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 EXPERIMENTAL_MODULE [WINDOW_SECONDS]" >&2
  exit 2
fi

experimental_module=$1
window_seconds=${2:-600}
kernel_release=$(uname -r)
baseline_module="/lib/modules/$kernel_release/updates/usb-16x16/usb_f_uac2.ko"
expected_baseline_sha256=8e9907d3363d80d3c93e8b24b5576e7dbd683cd6cb415580970364bc20c320e4
expected_experimental_sha256=87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e
expected_setup_sha256=d3031e22192ad69bcc3d3a59c3b54898f3f5ff73973720643256a115e469afa3
experimental_active=0

for value in "$window_seconds"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 60 ] || [ "$value" -gt 1800 ]; then
    echo "window must be 60..1800 seconds" >&2
    exit 3
  fi
done
if [ "$(sha256sum "$baseline_module" | awk '{print $1}')" != "$expected_baseline_sha256" ] ||
   [ "$(sha256sum /usr/local/sbin/setup-usb-16x16 | awk '{print $1}')" != "$expected_setup_sha256" ]; then
  echo "protected USB baseline hash mismatch" >&2
  exit 4
fi
if [ "$(sha256sum "$experimental_module" | awk '{print $1}')" != "$expected_experimental_sha256" ]; then
  echo "experimental module hash mismatch" >&2
  exit 5
fi
if pgrep -x aes67-daemon >/dev/null || pgrep -x alsaloop >/dev/null ||
   pgrep -x usb16x16-rt-bridge >/dev/null || lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing descriptor test while an AES67/audio candidate is active" >&2
  exit 6
fi

restore_baseline() {
  set +e
  if [ "$experimental_active" -eq 1 ]; then
    systemctl stop usb-16x16.service
    /usr/sbin/rmmod usb_f_uac2 2>/dev/null || true
    /usr/sbin/modprobe u_audio
    /usr/sbin/modprobe usb_f_uac2
    systemctl start usb-16x16.service
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(cat /sys/class/udc/*/state 2>/dev/null)" = configured ] &&
        [ "$(cat /sys/class/udc/*/current_speed 2>/dev/null)" = high-speed ] && break
      sleep 1
    done
    echo "baseline restored: $(sha256sum "$baseline_module" | awk '{print $1}')"
    echo "usb state: $(cat /sys/class/udc/*/state) / $(cat /sys/class/udc/*/current_speed)"
  fi
}
trap restore_baseline EXIT HUP INT TERM

systemctl stop usb-16x16.service
/usr/sbin/rmmod usb_f_uac2
/usr/sbin/modprobe u_audio
/usr/sbin/insmod "$experimental_module"
experimental_active=1
systemctl start usb-16x16.service

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$(cat /sys/class/udc/*/state 2>/dev/null)" = configured ] &&
     [ "$(cat /sys/class/udc/*/current_speed 2>/dev/null)" = high-speed ]; then
    break
  fi
  sleep 1
done
if [ "$(cat /sys/class/udc/*/state)" != configured ] ||
   [ "$(cat /sys/class/udc/*/current_speed)" != high-speed ]; then
  echo "experimental gadget did not enumerate configured/high-speed" >&2
  exit 7
fi

echo "EXPERIMENT READY for $window_seconds seconds"
echo "Verify input and output labels 1..16 in Audio MIDI Setup and Pro Tools."
echo "The known-good module will be restored automatically when this window ends."
sleep "$window_seconds"
