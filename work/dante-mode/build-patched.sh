#!/bin/bash
# Builds the Inferno ALSA plugin from the pinned tree plus a set of patches, as
# an artifact of its own beside the stock one, and puts the pinned tree and the
# stock build product back exactly as they were:
#   build-patched.sh                                   plugins/xrun-option/  = pinned + 0001
#   build-patched.sh NAME PATCH [PATCH...]             plugins/NAME/         = pinned + those, in order
#   e.g. build-patched.sh xrun-option-retry1 0001 0002
# PATCH is the number a file in patches/ begins with. plugins/stock/ holds a copy
# of the pinned build (SOURCES.lock). Select one with ALSA_PLUGIN_DIR.
# inferno/target/release keeps the stock file, so the probe and prototype
# wrappers are unchanged. Run on the Pi, unprivileged, with nothing using the
# plugin. OWNER_DESIGN.md step 2; PLAN.md stage 3a step 3.
set -u
. "$HOME/.cargo/env"
base="$HOME/usb-16x16-work/dante-mode"
name="${1:-xrun-option}"
[ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- 0001
stock_sha="ca99efd703bbf1d0dbed531aefe60f5d97401050f0278bf05a8c56d933c9a570"
so="$base/inferno/target/release/libasound_module_pcm_inferno.so"
# The pinned source files a patch here may touch, with their hashes: checked
# before the build and again after the patches are taken back out.
pinned="903c8697d2254ff37416b3618d7135ac8b11b9095eba2d390d6e65df623106c8  alsa_pcm_inferno/src/lib.rs
c1bb711373b9e371d0e4729269878d763782c02b822e3f227412c0914e2640de  inferno_aoip/src/device_server/channels_subscriber.rs"

refuse() { echo "REFUSED: $*"; echo "BUILD_EXIT 99"; exit 99; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
systemctl is-active --quiet usb16x16-aes67.service && refuse "usb16x16-aes67.service is active (no builds beside it)"
for process in alsaloop inferno-probe usb16x16-dante-; do   # pgrep -x sees 15 characters of a name
    pgrep -x "$process" > /dev/null && refuse "$process is running"
done
[ "$name" != stock ] || refuse "stock is the pinned build's name"
files=()
for number in "$@"; do
    match=("$base"/patches/"$number"-*.patch)
    [ -f "${match[0]}" ] || refuse "no patch $number in $base/patches"
    files+=("${match[0]}")
done
[ "$(sha "$so")" = "$stock_sha" ] || refuse "target/release does not hold the pinned plugin"
cd "$base/inferno" || refuse "no inferno tree"
echo "$pinned" | sha256sum -c --quiet - || refuse "the source is not the pinned source"

mkdir -p "$base/plugins/stock" "$base/plugins/$name"
cp -p "$so" "$base/plugins/stock/" || refuse "could not keep the stock plugin"

applied=()
restore() {
    local index
    for (( index=${#applied[@]}-1; index>=0; index-- )); do
        patch -R -p1 -s < "${applied[index]}"
    done
    applied=()
    cp -p "$base/plugins/stock/libasound_module_pcm_inferno.so" "$so"
}
trap restore EXIT

for file in "${files[@]}"; do
    patch -p1 --dry-run -s < "$file" > /dev/null || refuse "$(basename "$file") does not apply"
    patch -p1 -s < "$file"
    applied+=("$file")
    echo "applied $(basename "$file") $(sha "$file" | cut -c1-8)"
done
date -u +"start %FT%TZ"
cargo build --release --locked -j2 -p alsa_pcm_inferno; rc=$?
date -u +"inferno rc=$rc %FT%TZ"
[ "$rc" -eq 0 ] && cp "$so" "$base/plugins/$name/"
restore
trap - EXIT
if echo "$pinned" | sha256sum -c --quiet -; then echo "source restored to the pin"; else echo "SOURCE NOT RESTORED"; rc=98; fi
echo "target/release:  $(sha "$so")"
sha256sum "$base"/plugins/*/libasound_module_pcm_inferno.so
echo
echo "BUILD_EXIT $rc"
