#!/bin/bash
# build-rate-request.sh: build the Mac-follow experiment (RATE_REPORT_PLAN.md,
# "Mac-follow experiment") on the Pi, as the normal user, without touching the
# kernel source tree or anything installed. Run from the directory holding this
# script and the four patches (staged as ~/usb-16x16-work/gadget-raterequest/).
#
# Two builds in build/, from copies of the tree's sources, as build-rate-report.sh:
#   control/       the label sources plus uac2-rate-report-6.18.34.patch: says whether
#                  this build reproduces the installed rate-report pair.
#   rate-request/  the same plus uac2-rate-request-experiment-6.18.34.patch: the
#                  experiment candidate, for test-rate-request.sh only, never installed.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${KERNEL_TREE:-$HOME/src/linux-6.18.34}/drivers/usb/gadget/function
kdir=/lib/modules/$(uname -r)/build
expected_kernel_release=6.18.34+rpt-rpi-2712
installed_u_audio_sha256=b2f5c6cd7c4e25a0d62f6e603ce974b598a269688a3ef79db8c884c7994b4446
installed_f_uac2_sha256=fa8bed124e6755695f056a24b448d2fda0027ef1e19fe2fa512533eb3db1f093

[ "$(uname -r)" = "$expected_kernel_release" ] || { echo "kernel is $(uname -r), not $expected_kernel_release" >&2; exit 3; }
for f in uac2-shared-clock-6.18.34.patch uac2-discrete-channel-names-6.18.34.patch \
         uac2-rate-report-6.18.34.patch uac2-rate-request-experiment-6.18.34.patch; do
  [ -r "$here/$f" ] || { echo "missing $here/$f" >&2; exit 2; }
done

sha() { sha256sum "$1" | awk '{print $1}'; }

prepare() {   # prepare DIR: copies of the tree's sources with the label and rate-report patches
  local dir=$1
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$tree/u_audio.c" "$tree/u_audio.h" "$tree/u_uac2.h" "$tree/uac_common.h" "$dir/"
  cp "$tree/f_uac2.c.before-shared-clock" "$dir/f_uac2.c"
  patch -s -p5 -d "$dir" < "$here/uac2-shared-clock-6.18.34.patch"
  patch -s -p5 -d "$dir" < "$here/uac2-discrete-channel-names-6.18.34.patch"
  patch -s -p5 -d "$dir" < "$here/uac2-rate-report-6.18.34.patch"
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

echo "control build (the rate-report pair)"
prepare "$here/build/control"
make -s -C "$kdir" M="$here/build/control" modules >"$here/build/control.log" 2>&1 || { tail -20 "$here/build/control.log"; exit 4; }
report "$here/build/control"
if [ "$(sha "$here/build/control/u_audio.ko")" = "$installed_u_audio_sha256" ] &&
   [ "$(sha "$here/build/control/usb_f_uac2.ko")" = "$installed_f_uac2_sha256" ]; then
  echo "  control reproduces the installed rate-report pair"
else
  echo "  control differs from the installed rate-report pair (b2f5c6cd / fa8bed12)"
fi

echo "rate-request build"
prepare "$here/build/rate-request"
patch -s -p5 -d "$here/build/rate-request" < "$here/uac2-rate-request-experiment-6.18.34.patch"
make -s -C "$kdir" M="$here/build/rate-request" modules >"$here/build/rate-request.log" 2>&1 || { tail -20 "$here/build/rate-request.log"; exit 5; }
if grep -E 'warning|error' "$here/build/rate-request.log"; then echo "the build has warnings; see build/rate-request.log" >&2; exit 6; fi
report "$here/build/rate-request"
echo "  usb_f_uac2 needs: $(/usr/sbin/modinfo -F depends "$here/build/rate-request/usb_f_uac2.ko")"
