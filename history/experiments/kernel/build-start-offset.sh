#!/bin/bash
# build-start-offset.sh: build the Playback Start Offset modules (work/mac-driver-spike/
# SPIKE_PLAN.md, "Phase C") on the Pi, as the normal user, without touching the kernel
# source tree or anything installed. Run from the directory holding this script and the
# patches (staged as ~/usb-16x16-work/gadget-startoffset/).
#
# Two builds in build/, from copies of the tree's sources, as build-rate-request.sh:
#   control/       the label sources plus the rate-report and rate-request patches: says
#                  whether this build reproduces the installed rate-request pair.
#   start-offset/  the same plus uac2-start-offset-6.18.34.patch (a read-only control,
#                  counting only); for test-start-offset.sh, never installed.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${KERNEL_TREE:-$HOME/src/linux-6.18.34}/drivers/usb/gadget/function
kdir=/lib/modules/$(uname -r)/build
expected_kernel_release=6.18.34+rpt-rpi-2712
installed_u_audio_sha256=ed539ca898298b3d90863db51808153f83a702f4f330d08bb12753ed7b9baf57
installed_f_uac2_sha256=505c6ad0bad44f92f5487988d2f192efd9bd7018b7fc60e45e86c90080e20fe2

[ "$(uname -r)" = "$expected_kernel_release" ] || { echo "kernel is $(uname -r), not $expected_kernel_release" >&2; exit 3; }
for f in uac2-shared-clock-6.18.34.patch uac2-discrete-channel-names-6.18.34.patch \
         uac2-rate-report-6.18.34.patch uac2-rate-request-6.18.34.patch uac2-start-offset-6.18.34.patch; do
  [ -r "$here/$f" ] || { echo "missing $here/$f" >&2; exit 2; }
done

sha() { sha256sum "$1" | awk '{print $1}'; }

prepare() {   # prepare DIR: copies of the tree's sources with the installed patches
  local dir=$1
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$tree/u_audio.c" "$tree/u_audio.h" "$tree/u_uac2.h" "$tree/uac_common.h" "$dir/"
  cp "$tree/f_uac2.c.before-shared-clock" "$dir/f_uac2.c"
  patch -s -p5 -d "$dir" < "$here/uac2-shared-clock-6.18.34.patch"
  patch -s -p5 -d "$dir" < "$here/uac2-discrete-channel-names-6.18.34.patch"
  patch -s -p5 -d "$dir" < "$here/uac2-rate-report-6.18.34.patch"
  patch -s -p5 -d "$dir" < "$here/uac2-rate-request-6.18.34.patch"
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

echo "control build (the rate-request pair)"
prepare "$here/build/control"
make -s -C "$kdir" M="$here/build/control" modules >"$here/build/control.log" 2>&1 || { tail -20 "$here/build/control.log"; exit 4; }
report "$here/build/control"
if [ "$(sha "$here/build/control/u_audio.ko")" = "$installed_u_audio_sha256" ] &&
   [ "$(sha "$here/build/control/usb_f_uac2.ko")" = "$installed_f_uac2_sha256" ]; then
  echo "  control reproduces the installed rate-request pair"
else
  echo "  control differs from the installed rate-request pair (ed539ca8 / 505c6ad0)"
  exit 7
fi

echo "start-offset build (uac2-start-offset-6.18.34.patch)"
prepare "$here/build/start-offset"
patch -s -p5 -d "$here/build/start-offset" < "$here/uac2-start-offset-6.18.34.patch"
make -s -C "$kdir" M="$here/build/start-offset" KCFLAGS=-Werror modules >"$here/build/start-offset.log" 2>&1 ||
  { tail -20 "$here/build/start-offset.log"; exit 5; }
if grep -E 'warning|error' "$here/build/start-offset.log"; then echo "the build has warnings; see build/start-offset.log" >&2; exit 6; fi
report "$here/build/start-offset"
echo "  usb_f_uac2 needs: $(/usr/sbin/modinfo -F depends "$here/build/start-offset/usb_f_uac2.ko")"
