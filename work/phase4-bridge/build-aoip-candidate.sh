#!/bin/bash
# Build the loop-mode candidate bridge on the Pi, from a staged copy of
# work/phase4-bridge (CMakeLists.txt, include/, src/, tests/) at
# ~/usb-16x16-work/phase4-aoip-src. No root. Refuses while the AES67 service
# is active: a compile beside the running bridge has stalled it three times
# for three (handoff 2026-09-04), whatever the nice level.
#
# Prints the bridge hash at the end; that hash goes into
# work/aes67-candidate/run-aoip-candidate-safe.sh (expected_bridge_sha256)
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
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release > build/cmake.log 2>&1 || { tail -20 build/cmake.log >&2; exit 1; }
cmake --build build --target usb16x16-rt-bridge usb16x16_bridge_tests -j 2 > build/build.log 2>&1 || { tail -40 build/build.log >&2; exit 1; }
echo "warnings in build.log: $(grep -ci warning build/build.log || true)"
./build/usb16x16_bridge_tests
# Argument-level self-checks that open no device: the parser refuses what the
# design says it must, and accepts the loop's own list.
if ./build/usb16x16-rt-bridge --mode aoip-loop --usb-pitch-servo 1 --seconds 1 2>&1 | grep -q 'opens no USB gadget'; then
  echo "parser: loop mode refuses the pitch servo, as designed"
else
  echo "parser: loop mode did NOT refuse the pitch servo" >&2; exit 1
fi
if ./build/usb16x16-rt-bridge --mode aoip-loop --align-rx-trigger 1 --align-start 1 --seconds 1 2>&1 | grep -q 'no ravenna-to-usb direction'; then
  echo "parser: loop mode refuses the RX trigger, as designed"
else
  echo "parser: loop mode did NOT refuse the RX trigger" >&2; exit 1
fi
if ./build/usb16x16-rt-bridge --loop-impulse 1,2 --seconds 1 2>&1 | grep -q 'needs --mode aoip-loop'; then
  echo "parser: the injector needs loop mode, as designed"
else
  echo "parser: the injector did NOT need loop mode" >&2; exit 1
fi
if ./build/usb16x16-rt-bridge --mode sideways --seconds 1 2>&1 | grep -q 'mode must be'; then
  echo "parser: an unknown mode is refused"
else
  echo "parser: an unknown mode was NOT refused" >&2; exit 1
fi
sha256sum build/usb16x16-rt-bridge
