#!/bin/bash
# build-owner-idlephase.sh
#
# On the unit, unprivileged, from the bundle stage-owner-idlephase.sh made:
# build the owner with the --idle-phase option (usb16x16-dante-owner: the
# tree's dante/owner/main.cpp with dante/owner/idle-phase.patch applied) into
# <bundle>/out/, check that it runs and knows the option, and print its hash.
# It stops nothing and installs nothing; the audio keeps playing (the build
# takes a minute or two of CPU on a Pi 5: not during a measurement).
#
# The sources are copied to <bundle>/build/src and patched there, so the
# bundle's src/ stays what the list pins. The build line is
# build-owner-monitor.sh's (install/install.sh's): one g++ line, sources given
# relative to the source directory, so the binary does not depend on where the
# bundle was unpacked.
#
# Then: the hash in out/BUILD.txt must be OWNER_NEW in install-owner-idlephase.sh
# (bb3cd6ca, the candidate measured 2026-11-20); the installer refuses another.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
say() { echo "build-owner-idlephase: $*"; }
die() { echo "build-owner-idlephase: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
# main.cpp after the patch: 8c9bf80e (the installed owner bc486911's source) with idle-phase.patch.
PATCHED_MAIN=4d885b76578ec6e07b6de9464ea167ac6cb2784a870f956163ea3b8b8b5fbe12

[ "$(id -u)" -ne 0 ] || die "run this as yourself, not as root: it builds, it installs nothing"
[ -r "$here/owner-idlephase.sha256" ] || die "no owner-idlephase.sha256 beside this script"
while read -r want path; do
  [ -n "$want" ] || continue
  [ "$(sha "$here/$path")" = "$want" ] || die "$path is not $(echo "$want" | cut -c1-8) in the list; stage the bundle again"
done < "$here/owner-idlephase.sha256"
for tool in g++ patch; do command -v "$tool" >/dev/null || die "$tool is not installed (sudo apt-get install build-essential patch libasound2-dev)"; done
printf '#include <alsa/asoundlib.h>\n' | g++ -x c++ -fsyntax-only - 2>/dev/null || die "no ALSA headers (sudo apt-get install libasound2-dev)"

rm -rf "$here/out" "$here/build"
mkdir -p "$here/out" "$here/build"
cp -R "$here/src" "$here/build/src"

say "applying idle-phase.patch"
( cd "$here/build/src" && patch -p1 -s < "$here/src/dante/owner/idle-phase.patch" ) || die "idle-phase.patch does not apply to the bundle's main.cpp"
[ "$(sha "$here/build/src/dante/owner/main.cpp")" = "$PATCHED_MAIN" ] ||
  die "the patched main.cpp is $(sha "$here/build/src/dante/owner/main.cpp" | cut -c1-8), not $(echo "$PATCHED_MAIN" | cut -c1-8)"

say "building the owner"
( cd "$here/build/src" && g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror \
    -I dante/owner -I dsp-core/include -o "$here/out/usb16x16-dante-owner" \
    dante/owner/main.cpp dsp-core/src/bridge_core.cpp -lasound -lpthread )

# --- does it run
owner=$here/out/usb16x16-dante-owner
help=$("$owner" --help 2>&1 || true)
grep -q -- --idle-phase <<< "$help" || die "the owner's --help does not show --idle-phase"

owner_sha=$(sha "$owner")
{
  echo "usb16x16-dante-owner  $owner_sha"
  echo "patched main.cpp      $(sha "$here/build/src/dante/owner/main.cpp")"
  echo "source list           $(sha "$here/owner-idlephase.sha256")"
  echo "compiler              $(g++ --version | head -1)"
  echo "machine               $(uname -srm)"
  echo "built                 $(date -u +%Y-%m-%dT%H:%M:%SZ) in $here"
} > "$here/out/BUILD.txt"
cat "$here/out/BUILD.txt"
cat <<EOF
build-owner-idlephase: built and checked; nothing was installed. Next:
  the owner's hash above must be OWNER_NEW in install-owner-idlephase.sh (bb3cd6ca); then:
  ./install-owner-idlephase.sh status && sudo ./install-owner-idlephase.sh install
EOF
