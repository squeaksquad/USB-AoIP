#!/bin/bash
# Build the RAVENNA module with the transmit-slot fix (0001, work/ravenna-tx-fix)
# and the arrival-lead export (0002, work/ravenna-lead-export) from the pristine
# v2.1 tree, the way ravenna-tx-fix was built (README there). Run on the Pi from
# ~/usb-16x16-work/ravenna-lead-src, only with usb16x16-aes67.service stopped;
# no root. Leaves the module in ~/usb-16x16-work/ravenna-lead-install/.
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(systemctl is-active usb16x16-aes67.service)" = active ]; then
  echo "usb16x16-aes67.service is active; stop it first" >&2; exit 1
fi
short() { sha256sum "$1" | cut -c1-8; }
[ "$(short 0001-send-the-slot-just-written.patch)" = a7e9bc28 ] || { echo "0001 patch is not a7e9bc28" >&2; exit 1; }
[ "$(short 0002-export-arrival-lead.patch)" = e45b16b6 ] || { echo "0002 patch is not e45b16b6" >&2; exit 1; }
src=/home/bdimaio/usb-16x16-work/aes67-source/ravenna-alsa-lkm-v2.1
install_dir=/home/bdimaio/usb-16x16-work/ravenna-lead-install
rm -rf build && mkdir build
cp -r "$src/common" "$src/driver" build/
rm -f build/driver/*.o build/driver/*.ko build/driver/*.mod* build/driver/modules.order build/driver/Module.symvers build/driver/.*.cmd
rm -rf build/driver/.tmp_versions
(cd build && patch -p1 < ../0001-send-the-slot-just-written.patch && patch -p1 < ../0002-export-arrival-lead.patch)
[ "$(short build/driver/manager.c)" = 9cbbc5a8 ] || { echo "patched manager.c is not 9cbbc5a8" >&2; exit 1; }
[ "$(short build/driver/RTP_audio_stream.c)" = 5d479dda ] || { echo "patched RTP_audio_stream.c is not 5d479dda" >&2; exit 1; }
[ "$(short build/driver/RTP_audio_stream.h)" = d4e9fbc8 ] || { echo "patched RTP_audio_stream.h is not d4e9fbc8" >&2; exit 1; }
(cd build/driver && make modules > ../../build.log 2>&1) || { tail -30 build.log >&2; exit 1; }
echo "warnings in build.log: $(grep -ci warning build.log || true)"
echo "vermagic: $(modinfo -F vermagic build/driver/MergingRavennaALSA.ko) (running $(uname -r))"
mkdir -p "$install_dir"
cp build/driver/MergingRavennaALSA.ko "$install_dir/"
sha256sum "$install_dir/MergingRavennaALSA.ko"
