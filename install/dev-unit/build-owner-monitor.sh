#!/bin/bash
# build-owner-monitor.sh [JOBS]
#
# On the unit, unprivileged, from the bundle stage-owner-monitor.sh made:
# build the phase 3 owner (usb16x16-dante-owner, the monitor block) and the
# offline runner (usb16x16-dsp-offline, which knows the artifact's monitor
# section) into <bundle>/out/, check that both run, and print their hashes.
# It stops nothing and installs nothing; the audio keeps playing (the build
# takes a few minutes of CPU on a Pi 5: not during a measurement).
#
# The build lines are install/install.sh's: the owner with one g++ line and
# its flags, the runner by dsp-core's CMake file, Release, no tests. The
# sources are given relative to the bundle's src/, so the binaries do not
# depend on where the bundle was unpacked.
#
# Then: report the two hashes (they are in out/BUILD.txt) so they are pinned
# in install-owner-monitor.sh (OWNER_NEW, RUNNER_NEW) in the repository; an
# install is always of a binary whose hash is on the record.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
jobs=${1:-$(nproc 2>/dev/null || echo 2)}
say() { echo "build-owner-monitor: $*"; }
die() { echo "build-owner-monitor: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

[ "$(id -u)" -ne 0 ] || die "run this as yourself, not as root: it builds, it installs nothing"
[ -r "$here/owner-monitor.sha256" ] || die "no owner-monitor.sha256 beside this script"
while read -r want path; do
  [ -n "$want" ] || continue
  [ "$(sha "$here/$path")" = "$want" ] || die "$path is not $(echo "$want" | cut -c1-8) in the list; stage the bundle again"
done < "$here/owner-monitor.sha256"
for tool in g++ cmake; do command -v "$tool" >/dev/null || die "$tool is not installed (sudo apt-get install build-essential cmake libasound2-dev)"; done
printf '#include <alsa/asoundlib.h>\n' | g++ -x c++ -fsyntax-only - 2>/dev/null || die "no ALSA headers (sudo apt-get install libasound2-dev)"

rm -rf "$here/out" "$here/build"
mkdir -p "$here/out" "$here/build"

say "building the owner"
( cd "$here/src" && g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror \
    -I dante/owner -I dsp-core/include -o "$here/out/usb16x16-dante-owner" \
    dante/owner/main.cpp dsp-core/src/bridge_core.cpp -lasound -lpthread )

say "building the DSP runner"
cmake -S "$here/src/dsp-core" -B "$here/build/dsp-core" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
cmake --build "$here/build/dsp-core" --target usb16x16-dsp-offline -j"$jobs" >/dev/null
cp "$here/build/dsp-core/usb16x16-dsp-offline" "$here/out/usb16x16-dsp-offline"

# --- do they run
owner=$here/out/usb16x16-dante-owner runner=$here/out/usb16x16-dsp-offline
help=$("$owner" --help 2>&1 || true)
for option in --monitor-state --monitor-saved --monitor-limits --monitor-status --no-monitor; do
  grep -q -- "$option" <<< "$help" || die "the owner's --help does not show $option"
done
# The applier decides whether an engine knows the monitor section by this literal in the binary
# (web-control/usb16x16-apply, MONITOR_LOADER_MARK): both binaries must carry it.
for binary in "$owner" "$runner"; do
  grep -q 'dsp artifact: monitor: ' "$binary" || die "$(basename "$binary") does not carry the monitor loader's messages"
done
# A small artifact with a monitor section (dsp-compiler/fixtures/pinned-monitor-vector.dsp as of
# 2026-11-18): the runner loads it and runs one block, as the applier's load check does.
cat > "$here/build/monitor-check.dsp" <<'EOF'
usb16x16-dsp 1
preset pinned monitor vector
rate 48000
channels 16
internal 2
maxdelay 480
expand 2
0 0 0.125
1 1 -0.5
branch 1
1 2
1 0 0 0 0
0.5 0.25 0 -0.1 0.01
assign 2
0 0 1
3 1 0
output 16
0 48 0.5 1
1 0 0 0 0
1 0 1 0
2 0 1 0
3 0 1 0
4 0 1 0
5 0 1 0
6 0 1 0
7 0 1 0
8 0 1 0
9 0 1 0
10 0 1 0
11 0 1 0
12 0 1 0
13 0 1 0
14 0 1 0
15 0 1 0
monitor 1
sets 2
set front speakers
set cans headphones
outs 3
out 0 speaker 0
out 3 sub 0
out 5 speaker 1
label 0 Left  main
label 3 Sub
expandsets 2
0
-
folds 2
fold 0 stereo 2
0 0 1
0 2 0.7071067811865476
fold 0 mono 3
0 0 0.5
0 1 0.5
3 3 1
end
EOF
bench=$("$runner" "$here/build/monitor-check.dsp" --bench 1 2>&1) || die "the runner refused the monitor artifact: $(echo "$bench" | head -2)"

owner_sha=$(sha "$owner"); runner_sha=$(sha "$runner")
{
  echo "usb16x16-dante-owner  $owner_sha"
  echo "usb16x16-dsp-offline  $runner_sha"
  echo "source list           $(sha "$here/owner-monitor.sha256")"
  echo "compiler              $(g++ --version | head -1)"
  echo "cmake                 $(cmake --version | head -1)"
  echo "machine               $(uname -srm)"
  echo "built                 $(date -u +%Y-%m-%dT%H:%M:%SZ) in $here"
  echo "runner check          $(echo "$bench" | head -1)"
} > "$here/out/BUILD.txt"
cat "$here/out/BUILD.txt"
cat <<EOF
build-owner-monitor: built and checked; nothing was installed. Next:
  report the two hashes above (out/BUILD.txt) to be pinned as OWNER_NEW and RUNNER_NEW in
  install/dev-unit/install-owner-monitor.sh; then, with that installer in this directory:
  ./install-owner-monitor.sh status && sudo ./install-owner-monitor.sh install
EOF
