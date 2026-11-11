#!/bin/bash
# prepare-sources.sh KERNELVER [OUTDIR]
#
# Make the patched UAC2 gadget sources for one kernel: the five files of
# drivers/usb/gadget/function that build u_audio.ko and usb_f_uac2.ko, as that
# kernel's upstream release has them, with this project's four patches
# applied in order. DKMS runs it before each build (dkms.conf, PRE_BUILD), so
# a kernel upgrade rebuilds the modules from that kernel's own sources.
#
# Where the pristine files come from, first that has them:
#   1. upstream/<X.Y.Z>/ beside this script, or /var/cache/usb-aoip-uac2/<X.Y.Z>/
#      (USB_AOIP_UAC2_CACHE): a machine without network can be given the files there
#   2. the stable kernel tag v<X.Y.Z>, fetched over HTTPS
# The gadget function directory is the same in Raspberry Pi's tree and the
# stable tree at 6.18.34 (compared 2026-11-10); a vendor tree that changes it
# would show up below as a patch that does not apply.
#
# Refusals are loud and specific, and leave no half-patched build directory:
#   exit 3  the sources for this kernel could not be had
#   exit 4  they are not the files pinned for this version (upstream.sha256)
#   exit 5  a patch does not apply exactly (no fuzz is allowed: a hunk that
#           only fits loosely may land in changed code): this kernel changed the gadget code, and
#           the patches need porting before the modules can be built for it
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
kernelver=${1:?usage: prepare-sources.sh KERNELVER [OUTDIR]}
out=${2:-$here/build}
files="f_uac2.c u_audio.c u_audio.h u_uac2.h uac_common.h"
patches="uac2-shared-clock-6.18.34.patch uac2-discrete-channel-names-6.18.34.patch uac2-rate-report-6.18.34.patch uac2-rate-request-6.18.34.patch"
# Installed under /usr/src the patches sit in patches/; in the repository, one level up.
patch_dir=$here/patches; [ -d "$patch_dir" ] || patch_dir=$here/..
subdir=drivers/usb/gadget/function

# 6.18.34+rpt-rpi-2712 -> 6.18.34
base=$(printf '%s' "$kernelver" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
[ -n "$base" ] || { echo "usb-aoip-uac2: cannot read a kernel version X.Y.Z from '$kernelver'" >&2; exit 3; }

say() { echo "usb-aoip-uac2: $*" >&2; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

# A seeded copy beside this script wins; otherwise a cache that outlives the
# DKMS build directory, which is made afresh for every build.
cache=$here/upstream/$base
complete=1; for f in $files; do [ -s "$cache/$f" ] || complete=0; done
if [ "$complete" = 0 ]; then
  cache=${USB_AOIP_UAC2_CACHE:-/var/cache/usb-aoip-uac2}/$base
  mkdir -p "$cache" 2>/dev/null || cache=$here/upstream/$base
fi
fetch() {   # fetch FILE into the cache from the first mirror that has it
  local f=$1 url
  for url in \
    "https://raw.githubusercontent.com/gregkh/linux/v$base/$subdir/$f" \
    "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/$subdir/$f?h=v$base"; do
    if curl -fsSL --retry 2 --max-time 60 -o "$cache/$f.part" "$url"; then
      mv -f "$cache/$f.part" "$cache/$f"; return 0
    fi
  done
  rm -f "$cache/$f.part"
  return 1
}

mkdir -p "$cache"
for f in $files; do
  [ -s "$cache/$f" ] && continue
  command -v curl >/dev/null 2>&1 || { say "no cached sources for $base in $cache and no curl to fetch them"; exit 3; }
  fetch "$f" || {
    say "could not fetch $subdir/$f for Linux $base (no network, or no such release tag)."
    say "put the five files ($files) from that kernel's source in $cache and run again."
    exit 3
  }
done

# Pinned hashes, where this version has been built before; a version with none
# is accepted on the patches applying, and its hashes are printed to be recorded.
pins=$here/upstream.sha256
if grep -q "  $base/" "$pins" 2>/dev/null; then
  for f in $files; do
    want=$(sed -n "s|^\([0-9a-f]\{64\}\)  $base/$f\$|\1|p" "$pins")
    [ -n "$want" ] || { say "$pins lists Linux $base but not $f"; exit 4; }
    [ "$(sha "$cache/$f")" = "$want" ] || {
      say "$cache/$f is not the file pinned for Linux $base (sha256 $(sha "$cache/$f" | cut -c1-8), want ${want:0:8})."
      say "remove $cache to fetch it again."
      exit 4
    }
  done
else
  say "Linux $base has no pinned source hashes; accepting it if the patches apply. Hashes:"
  for f in $files; do say "  $(sha "$cache/$f")  $base/$f"; done
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/usb-aoip-uac2.XXXXXX")
trap 'rm -rf "$work"' EXIT
for f in $files; do cp "$cache/$f" "$work/$f"; done
for p in $patches; do
  [ -r "$patch_dir/$p" ] || { say "missing $patch_dir/$p"; exit 5; }
  if ! patch -s -p5 -F 0 --dry-run -d "$work" < "$patch_dir/$p" >/dev/null 2>&1; then
    say "REFUSED: $p does not apply to the Linux $base gadget sources."
    say "The patches were written against 6.18.34. This kernel changed"
    say "$subdir, so they need porting before the modules can"
    say "be built for it. Until then the stock modules load and the USB-AoIP"
    say "gadget will not start (it needs the patched ones). Stay on, or go back"
    say "to, a kernel the patches apply to; see docs/INSTALL.md, \"Kernel upgrades\"."
    exit 5
  fi
  patch -s -p5 -F 0 -d "$work" < "$patch_dir/$p"
done

rm -rf "$out"
mkdir -p "$out"
for f in $files; do cp "$work/$f" "$out/$f"; done
cp "$here/Kbuild" "$out/Kbuild"
say "sources for Linux $base ready in $out (four patches applied)"
