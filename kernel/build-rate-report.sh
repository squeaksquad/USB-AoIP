#!/bin/bash
# build-rate-report.sh: build the rate-report candidate (RATE_REPORT_PLAN.md, step 4)
# on the Pi, as the normal user, without touching the kernel source tree or anything
# installed. Run from the directory holding this script and the three patches
# (staged as ~/usb-16x16-work/gadget-ratereport/).
#
# Two builds in build/, from copies of the tree's sources:
#   control/      u_audio.c as shipped and the label f_uac2.c (before-shared-clock plus
#                 the shared-clock and channel-name patches): says whether this build
#                 reproduces the installed label module.
#   rate-report/  the same plus uac2-rate-report-6.18.34.patch: the candidate.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${KERNEL_TREE:-$HOME/src/linux-6.18.34}/drivers/usb/gadget/function
kdir=/lib/modules/$(uname -r)/build
expected_kernel_release=6.18.34+rpt-rpi-2712
label_module=/lib/modules/$expected_kernel_release/updates/usb-16x16/usb_f_uac2.ko
label_sha256=87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e

[ "$(uname -r)" = "$expected_kernel_release" ] || { echo "kernel is $(uname -r), not $expected_kernel_release" >&2; exit 3; }
for f in uac2-shared-clock-6.18.34.patch uac2-discrete-channel-names-6.18.34.patch uac2-rate-report-6.18.34.patch; do
  [ -r "$here/$f" ] || { echo "missing $here/$f" >&2; exit 2; }
done

sha() { sha256sum "$1" | awk '{print $1}'; }

prepare() {   # prepare DIR: copies of the tree's sources with the label patches applied
  local dir=$1
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$tree/u_audio.c" "$tree/u_audio.h" "$tree/u_uac2.h" "$tree/uac_common.h" "$dir/"
  cp "$tree/f_uac2.c.before-shared-clock" "$dir/f_uac2.c"
  patch -s -p5 -d "$dir" < "$here/uac2-shared-clock-6.18.34.patch"
  patch -s -p5 -d "$dir" < "$here/uac2-discrete-channel-names-6.18.34.patch"
  printf 'obj-m := u_audio.o usb_f_uac2.o\nusb_f_uac2-y := f_uac2.o\n' > "$dir/Kbuild"
}

report() {   # report DIR
  local dir=$1 m
  for m in u_audio usb_f_uac2; do
    printf '  %-12s sha256=%s vermagic=%s srcversion=%s\n' "$m" "$(sha "$dir/$m.ko")" \
      "$(/usr/sbin/modinfo -F vermagic "$dir/$m.ko" | awk '{print $1}')" "$(/usr/sbin/modinfo -F srcversion "$dir/$m.ko")"
  done
}

mkdir -p "$here/build"

echo "control build (no rate-report patch)"
prepare "$here/build/control"
make -s -C "$kdir" M="$here/build/control" modules >"$here/build/control.log" 2>&1 || { tail -20 "$here/build/control.log"; exit 4; }
report "$here/build/control"
if [ "$(sha "$here/build/control/usb_f_uac2.ko")" = "$label_sha256" ]; then
  echo "  control usb_f_uac2.ko reproduces the installed label module"
else
  echo "  control usb_f_uac2.ko differs from the installed label module ($label_sha256); srcversion installed: $(/usr/sbin/modinfo -F srcversion "$label_module")"
fi

echo "rate-report build"
prepare "$here/build/rate-report"
patch -s -p5 -d "$here/build/rate-report" < "$here/uac2-rate-report-6.18.34.patch"
make -s -C "$kdir" M="$here/build/rate-report" modules >"$here/build/rate-report.log" 2>&1 || { tail -20 "$here/build/rate-report.log"; exit 5; }
if grep -E 'warning|error' "$here/build/rate-report.log"; then echo "the build has warnings; see build/rate-report.log" >&2; exit 6; fi
report "$here/build/rate-report"
grep -q 'u_audio_forget_srate' "$here/build/rate-report/Module.symvers" || { echo "u_audio_forget_srate not exported" >&2; exit 7; }
echo "  u_audio_forget_srate exported; usb_f_uac2 needs: $(/usr/sbin/modinfo -F depends "$here/build/rate-report/usb_f_uac2.ko")"
