#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
if [ "$#" -ne 1 ]; then
  echo "usage: $0 DISCRETE_CHANNEL_MODULE" >&2
  exit 2
fi

candidate_module=$1
kernel_release=$(uname -r)
installed_module="/lib/modules/$kernel_release/updates/usb-16x16/usb_f_uac2.ko"
backup_module="$installed_module.pre-discrete-channels"
temporary_module="$installed_module.new"
expected_kernel_release=6.18.34+rpt-rpi-2712
expected_baseline_sha256=8e9907d3363d80d3c93e8b24b5576e7dbd683cd6cb415580970364bc20c320e4
expected_candidate_sha256=87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e
expected_setup_sha256=d3031e22192ad69bcc3d3a59c3b54898f3f5ff73973720643256a115e469afa3
install_started=0

sha256() {
  sha256sum "$1" | awk '{print $1}'
}

usb_healthy() {
  [ "$(cat /sys/class/udc/*/state 2>/dev/null)" = configured ] &&
    [ "$(cat /sys/class/udc/*/current_speed 2>/dev/null)" = high-speed ] &&
    [ "$(systemctl is-active usb-16x16.service)" = active ]
}

wait_for_usb() {
  for attempt in $(seq 1 20); do
    usb_healthy && return 0
    sleep 1
  done
  return 1
}

restore_baseline() {
  status=$?
  set +e
  rm -f "$temporary_module"
  if [ "$status" -ne 0 ] && [ "$install_started" -eq 1 ]; then
    echo "install failed; restoring the verified baseline module" >&2
    systemctl stop usb-16x16.service
    /usr/sbin/rmmod usb_f_uac2 2>/dev/null || true
    if [ -r "$backup_module" ] &&
       [ "$(sha256 "$backup_module")" = "$expected_baseline_sha256" ]; then
      install -o root -g root -m 0644 "$backup_module" "$installed_module"
      /usr/sbin/depmod -a "$kernel_release"
      /usr/sbin/modprobe u_audio
      /usr/sbin/modprobe usb_f_uac2
      systemctl start usb-16x16.service
      wait_for_usb || true
      echo "baseline restored: $(sha256 "$installed_module")" >&2
    else
      echo "verified baseline backup unavailable; USB service remains stopped" >&2
    fi
  fi
  exit "$status"
}
trap restore_baseline EXIT HUP INT TERM

if [ "$kernel_release" != "$expected_kernel_release" ]; then
  echo "kernel mismatch: expected $expected_kernel_release, got $kernel_release" >&2
  exit 3
fi
if [ ! -r "$candidate_module" ] ||
   [ "$(sha256 "$candidate_module")" != "$expected_candidate_sha256" ]; then
  echo "candidate module hash mismatch" >&2
  exit 4
fi
if [ "$(/usr/sbin/modinfo -F vermagic "$candidate_module" | awk '{print $1}')" != "$kernel_release" ]; then
  echo "candidate module vermagic mismatch" >&2
  exit 5
fi
if [ "$(sha256 /usr/local/sbin/setup-usb-16x16)" != "$expected_setup_sha256" ]; then
  echo "protected setup script hash mismatch" >&2
  exit 6
fi

installed_sha256=$(sha256 "$installed_module")
if [ "$installed_sha256" = "$expected_candidate_sha256" ]; then
  usb_healthy || { echo "label module is installed but USB is not healthy" >&2; exit 7; }
  echo "verified label module is already installed"
  exit 0
fi
if [ "$installed_sha256" != "$expected_baseline_sha256" ]; then
  echo "installed module is neither the verified baseline nor label candidate" >&2
  exit 8
fi
if pgrep -x ptp4l >/dev/null || pgrep -x aes67-daemon >/dev/null ||
   pgrep -x alsaloop >/dev/null ||
   pgrep -f '^/usr/local/libexec/usb16x16-rt-bridge([[:space:]]|$)' >/dev/null ||
   lsmod | grep -q '^MergingRavennaALSA '; then
  echo "refusing install while an AES67/audio candidate is active" >&2
  exit 9
fi
usb_healthy || { echo "protected USB baseline is not healthy" >&2; exit 10; }

if [ -e "$backup_module" ]; then
  if [ "$(sha256 "$backup_module")" != "$expected_baseline_sha256" ]; then
    echo "existing baseline backup hash mismatch" >&2
    exit 11
  fi
else
  install -o root -g root -m 0644 "$installed_module" "$backup_module"
fi

install_started=1
systemctl stop usb-16x16.service
/usr/sbin/rmmod usb_f_uac2
install -o root -g root -m 0644 "$candidate_module" "$temporary_module"
mv -f "$temporary_module" "$installed_module"
/usr/sbin/depmod -a "$kernel_release"
/usr/sbin/modprobe u_audio
/usr/sbin/modprobe usb_f_uac2
systemctl start usb-16x16.service

if ! wait_for_usb; then
  echo "label module did not enumerate configured/high-speed" >&2
  exit 12
fi
if [ "$(sha256 "$installed_module")" != "$expected_candidate_sha256" ]; then
  echo "installed label module hash mismatch" >&2
  exit 13
fi

install_started=0
trap - EXIT HUP INT TERM
echo "installed verified 1..16 channel-label module"
echo "baseline backup: $backup_module"
echo "usb state: $(cat /sys/class/udc/*/state) / $(cat /sys/class/udc/*/current_speed)"
