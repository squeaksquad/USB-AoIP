#!/bin/bash
# Build the live-coefficient candidate bridge (LIVE_COEFFICIENTS_DESIGN.md step 3) on the Pi, from a staged copy of
# work/phase4-bridge (CMakeLists.txt, include/, src/, tests/) at
# ~/usb-16x16-work/phase4-live-src. No root. Refuses while the AES67 service
# is active: a compile beside the running bridge has stalled it three times
# for three (handoff 2026-09-04), whatever the nice level.
#
# Prints the bridge hash at the end; that hash goes into
# work/aes67-candidate/run-dsp-candidate-safe.sh (expected_bridge_sha256)
# before the wrapper will run it.
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(systemctl is-active usb16x16-aes67.service)" = active ]; then
  echo "usb16x16-aes67.service is active; stop it first" >&2
  exit 1
fi
for path in CMakeLists.txt include/usb16x16/bridge_core.hpp src/bridge_core.cpp src/main.cpp tests/bridge_tests.cpp; do
  [ -r "$path" ] || { echo "missing $path" >&2; exit 1; }
done
echo "sources: main.cpp $(sha256sum src/main.cpp | cut -c1-8) bridge_core.cpp $(sha256sum src/bridge_core.cpp | cut -c1-8) bridge_core.hpp $(sha256sum include/usb16x16/bridge_core.hpp | cut -c1-8)"
mkdir -p build
# ALSA's headers are not installed system-wide on the Pi: they are the
# extracted libasound2-dev under deps/, the library is the runtime one, as
# every bridge build here has been configured (README, "Build").
alsa_include=/home/bdimaio/usb-16x16-work/deps/libasound2-dev/usr/include
alsa_library=/usr/lib/aarch64-linux-gnu/libasound.so.2
[ -r "$alsa_include/alsa/asoundlib.h" ] || { echo "missing $alsa_include/alsa/asoundlib.h" >&2; exit 1; }
[ -r "$alsa_library" ] || { echo "missing $alsa_library" >&2; exit 1; }
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DALSA_INCLUDE_DIR="$alsa_include" -DALSA_LIBRARY="$alsa_library" > build/cmake.log 2>&1 || { tail -20 build/cmake.log >&2; exit 1; }
grep -q 'ALSA development files not found' build/cmake.log && { echo "cmake did not take the ALSA paths" >&2; exit 1; }
cmake --build build --target usb16x16-rt-bridge usb16x16_bridge_tests -j 2 > build/build.log 2>&1 || { tail -40 build/build.log >&2; exit 1; }
echo "warnings in build.log: $(grep -ci warning build/build.log || true)"
./build/usb16x16_bridge_tests
# Argument-level self-checks that open no device: the parser refuses what the
# design says it must. The bridge exits 1 on each, which under pipefail would
# fail a pipeline into grep, so the output is captured first.
check() {
  local pattern=$1; shift
  local output
  output=$(./build/usb16x16-rt-bridge "$@" 2>&1 || true)
  grep -q "$pattern" <<<"$output"
}
check 'needs --dsp-preset' --dsp-live-file /tmp/x.dsp --seconds 1 &&
  echo "parser: the live file needs a preset, as designed" ||
  { echo "parser: the live file did NOT need a preset" >&2; exit 1; }
# The shape key the compiler, the applier and the bridge all pin.
cmake --build build --target usb16x16-dsp-offline -j 2 >> build/build.log 2>&1
printf 'usb16x16-dsp 1\npreset pinned shape vector\nrate 48000\nchannels 16\ninternal 2\nmaxdelay 480\nexpand 2\n0 0 0.125\n1 1 -0.5\nbranch 1\n1 2\n1 0 0 0 0\n0.5 0.25 0 -0.1 0.01\nassign 2\n0 0 1\n3 1 0\noutput 16\n0 48 0.5 1\n1 0 0 0 0\n' > build/vector.dsp
for i in $(seq 1 15); do printf '%s 0 1 0\n' "$i" >> build/vector.dsp; done
printf 'end\n' >> build/vector.dsp
key=$(./build/usb16x16-dsp-offline build/vector.dsp --shape | head -1)
[ "$key" = shape_key=7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0 ] &&
  echo "shape key: the pinned vector holds on this build" ||
  { echo "shape key mismatch: $key" >&2; exit 1; }
sha256sum build/usb16x16-rt-bridge
