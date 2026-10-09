#!/bin/bash
# Builds the Inferno ALSA plugin with patches/0001 (the XRUN_REPORT option) as a
# second artifact beside the stock one, and puts the pinned tree and the stock
# build product back exactly as they were:
#   plugins/stock/libasound_module_pcm_inferno.so        the pinned build (SOURCES.lock)
#   plugins/xrun-option/libasound_module_pcm_inferno.so  pinned tree + patches/0001
# Select one with ALSA_PLUGIN_DIR. inferno/target/release keeps the stock file,
# so the probe and prototype wrappers are unchanged. Run on the Pi, unprivileged,
# with nothing using the plugin. OWNER_DESIGN.md, step 2.
set -u
. "$HOME/.cargo/env"
base="$HOME/usb-16x16-work/dante-mode"
patch_file="$base/patches/0001-alsa-plugin-xrun-report-option.patch"
stock_sha="ca99efd703bbf1d0dbed531aefe60f5d97401050f0278bf05a8c56d933c9a570"
source_sha="903c8697d2254ff37416b3618d7135ac8b11b9095eba2d390d6e65df623106c8"
src="$base/inferno/alsa_pcm_inferno/src/lib.rs"
so="$base/inferno/target/release/libasound_module_pcm_inferno.so"

refuse() { echo "REFUSED: $*"; echo "BUILD_EXIT 99"; exit 99; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
systemctl is-active --quiet usb16x16-aes67.service && refuse "usb16x16-aes67.service is active (no builds beside it)"
for name in alsaloop inferno-probe usb16x16-dante-; do   # pgrep -x sees 15 characters of a name
    pgrep -x "$name" > /dev/null && refuse "$name is running"
done
[ -f "$patch_file" ] || refuse "no $patch_file"
[ "$(sha "$so")" = "$stock_sha" ] || refuse "target/release does not hold the pinned plugin"
[ "$(sha "$src")" = "$source_sha" ] || refuse "lib.rs is not the pinned source"

mkdir -p "$base/plugins/stock" "$base/plugins/xrun-option"
cp -p "$so" "$base/plugins/stock/" || refuse "could not keep the stock plugin"
cp -p "$src" "$base/patches/lib.rs.pinned" || refuse "could not keep the pinned source"

restore() {
    cp -p "$base/patches/lib.rs.pinned" "$src"
    cp -p "$base/plugins/stock/libasound_module_pcm_inferno.so" "$so"
}
trap restore EXIT

cd "$base/inferno" || refuse "no inferno tree"
patch -p1 --dry-run < "$patch_file" > /dev/null || refuse "the patch does not apply to the pinned tree"
patch -p1 < "$patch_file"
date -u +"start %FT%TZ"
cargo build --release --locked -j2 -p alsa_pcm_inferno; rc=$?
date -u +"inferno rc=$rc %FT%TZ"
[ "$rc" -eq 0 ] && cp "$so" "$base/plugins/xrun-option/"
restore
trap - EXIT
echo "source restored: $(sha "$src")"
echo "target/release:  $(sha "$so")"
sha256sum "$base"/plugins/*/libasound_module_pcm_inferno.so
echo
echo "BUILD_EXIT $rc"
