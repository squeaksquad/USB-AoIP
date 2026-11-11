#!/bin/zsh
# Run CamillaDSP and the bridge's own filter stage against each other on the
# Pi, on the same presets and the same input files, and compare the outputs
# sample by sample.
#
# Both engines run on the same machine, from the same compilation of the same
# preset: the YAML for CamillaDSP and the coefficient artifact for the bridge,
# emitted together so they cannot describe different pipelines. Comparing the
# raw output rather than the harnesses' derived numbers leaves nowhere for a
# difference to hide.
#
# It builds the bridge core and the offline runner on the Pi, so it refuses
# while usb16x16-aes67.service is up twice over: a compile on this machine has
# stalled the bridge before (2026-09-04, eight RECOVERs and a stack restart).
#
# Usage: run-headtohead.sh [LABEL]
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
label=${1:-headtohead}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$repo_root/outputs/dsp-verify/${label}-${timestamp}"
pi_dir="/home/bdimaio/usb-16x16-work/dsp-verify"
pi_build="$pi_dir/bridge-build"
camilladsp="/home/bdimaio/usb-16x16-work/camilladsp-v4.1.3/camilladsp"
offline="$pi_build/usb16x16-dsp-offline"

pi() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 "$@" 2>/dev/null ||
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@169.254.92.97 "$@"
}
put() {
  scp -q -o HostKeyAlias=audio-dev.local "$1" bdimaio@192.168.1.201:"$2" ||
    { print -r -- "exit=4"; exit 4; }
}

print -r -- "=== engine head to head ($timestamp)"
state=$(pi 'echo "$(systemctl is-active usb16x16-aes67) $(wc -l < /run/usb16x16/recovers 2>/dev/null || echo 0)"')
if [[ "${state%% *}" == active ]]; then
  print -r -- "usb16x16-aes67.service is running, and this builds on the Pi. Stop it first:"
  print -r -- "  sudo systemctl stop usb16x16-aes67"
  print -r -- "exit=2"
  exit 2
fi
recovers_before=${state##* }
print -r -- "service: ${state%% *}   recovers so far: $recovers_before"
mkdir -p "$out_dir"

# ---------------------------------------------------------------- compile
compile="$repo_root/work/dsp-compiler/usb16x16-dsp-compile"
presets="$repo_root/work/dsp-compiler/verify-presets.mjs"
# name:format[:shape] -- the format each preset's comparison runs in, and the
# compiler's shape (minimal unless given). default:s32le:fixed is the shipped
# layout in the fixed shape: 256 empty band slots as unity sections, which the
# bridge skips since 2026-10-17 and CamillaDSP runs as Free biquads.
cases=(crossover:f64le phones:s32le loaded:s32le default:s32le:fixed)
case_name() { local preset=${1%%:*} rest=${1#*:}; [[ $rest == *:fixed ]] && print -r -- "$preset-fixed" || print -r -- "$preset"; }
case_format() { local rest=${1#*:}; print -r -- "${rest%%:*}"; }
for entry in $cases; do
  preset=${entry%%:*}; name=$(case_name $entry); format=$(case_format $entry)
  shape=$([[ $entry == *:fixed ]] && echo fixed || echo minimal)
  node "$presets" "$preset" > "$out_dir/$name.json" || { print -r -- "exit=3"; exit 3; }
  camilla_format=$([[ $format == f64le ]] && echo F64_LE || echo S32_LE)
  "$compile" "$out_dir/$name.json" -o "$out_dir/$name.yml" \
    --bridge "$out_dir/$name.dsp" --report "$out_dir/$name-report.json" \
    --in "$pi_dir/$name-in.raw" --raw "$pi_dir/$name-camilla.raw" \
    --format "$camilla_format" --shape "$shape" >/dev/null 2>&1
done

# ---------------------------------------------------------------- build
print -r -- "--- building the bridge core and offline runner on the Pi"
pi "mkdir -p $pi_dir/src $pi_dir/include/usb16x16 $pi_dir/tests"
put "$repo_root/work/phase4-bridge/CMakeLists.txt" "$pi_dir/"
put "$repo_root/work/phase4-bridge/src/bridge_core.cpp" "$pi_dir/src/"
put "$repo_root/work/phase4-bridge/src/dsp_offline.cpp" "$pi_dir/src/"
# Every source CMakeLists.txt names, or the configure step fails and the build
# directory keeps whatever an earlier run left (2026-10-17: a run read the
# September binaries this way).
put "$repo_root/work/phase4-bridge/src/meter_bench.cpp" "$pi_dir/src/"
put "$repo_root/work/phase4-bridge/src/main.cpp" "$pi_dir/src/"
put "$repo_root/work/phase4-bridge/include/usb16x16/bridge_core.hpp" "$pi_dir/include/usb16x16/"
put "$repo_root/work/phase4-bridge/tests/bridge_tests.cpp" "$pi_dir/tests/"
pi "rm -f $offline $pi_build/usb16x16_bridge_tests"
build_log=$(pi "cd $pi_dir && cmake -S . -B bridge-build -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -3 && cmake --build bridge-build --target usb16x16-dsp-offline usb16x16_bridge_tests 2>&1 | tail -4; echo build=\$?")
print -r -- "$build_log"
# Both binaries must exist now, made by this build from the sources just copied.
built=$(pi "cd $pi_dir && [ -x $offline ] && [ -x $pi_build/usb16x16_bridge_tests ] && [ $offline -nt src/bridge_core.cpp ] && echo yes")
if [[ $built != yes ]]; then
  print -r -- "the build did not produce fresh binaries; nothing is compared"
  print -r -- "exit=6"
  exit 6
fi
print -r -- "core under test: bridge_core.cpp $(pi "sha256sum $pi_dir/src/bridge_core.cpp" | cut -c1-8), runner $(pi "sha256sum $offline" | cut -c1-8)"
print -r -- "--- the core suite, on the Pi"
pi "$pi_build/usb16x16_bridge_tests" || { print -r -- "core tests failed on the Pi"; print -r -- "exit=5"; exit 5; }

for file in bridge-engine-shim compare-engines.py verify-crossover.py verify-run.py; do
  put "$repo_root/work/dsp-compiler/$file" "$pi_dir/"
done
for entry in $cases; do
  name=$(case_name $entry)
  put "$out_dir/$name.yml" "$pi_dir/"
  put "$out_dir/$name.dsp" "$pi_dir/"
done

# ---------------------------------------------------------------- run
for entry in $cases; do
  name=$(case_name $entry); format=$(case_format $entry)
  print -r -- "--- $name ($format)"
  # The input is written once, by whichever harness generates it, and both
  # engines are then given that same file. Nothing regenerates it in between.
  if [[ $name == crossover ]]; then
    pi "cd $pi_dir && python3 verify-crossover.py $name.yml --camilladsp $camilladsp \
      --in $pi_dir/$name-in.raw --out $pi_dir/$name-camilla.raw \
      --pair 1,2,80 --pair 3,4,80 --pair 5,6,80 --pair 7,8,200 \
      --order 4 --order 2 --order 2 --order 8" > "$out_dir/$name-camilla.json"
  else
    pi "cd $pi_dir && python3 verify-run.py $name.yml --camilladsp $camilladsp \
      --in $pi_dir/$name-in.raw --out $pi_dir/$name-camilla.raw" > "$out_dir/$name-camilla.json"
  fi
  # Same input file, the bridge's stage, at the bridge's own 48-frame block.
  pi "cd $pi_dir && BRIDGE_OFFLINE=$offline BRIDGE_IN=$pi_dir/$name-in.raw \
    BRIDGE_OUT=$pi_dir/$name-bridge.raw BRIDGE_FORMAT=$format \
    ./bridge-engine-shim $pi_dir/$name.dsp" 2>&1 | tail -2
  pi "cd $pi_dir && python3 compare-engines.py $name-camilla.raw $name-bridge.raw \
    --format $format --label-reference camilladsp --label-candidate bridge" \
    > "$out_dir/$name-compare.json"
  python3 -c "
import json
r = json.load(open('$out_dir/$name-compare.json'))
print('  %d frames, identical: %s, worst difference %s dB below the signal that made it'
      % (r['frames'], r['identical'], r['worstRelativeDb']))
if r.get('warning'): print('  warning:', r['warning'])
for c in r['channels']:
    if c['differingSamples']:
        print('    out%-2d peak %8s dBFS  worst diff %9s dBFS (%s dB rel)  %d/%d samples differ'
              % (c['channel'], c['peakDbfs'], c['worstDiffDbfs'], c['worstDiffRelDb'],
                 c['differingSamples'], c['totalSamples']))"
done

pi "rm -f $pi_dir/*-in.raw $pi_dir/*-camilla.raw $pi_dir/*-bridge.raw"
after=$(pi 'echo "$(wc -l < /run/usb16x16/recovers 2>/dev/null || echo 0) $(systemctl is-active usb16x16-aes67)"')
print -r -- "recovers: $recovers_before before, ${after%% *} after   service: ${after##* }"
print -r -- "results in $out_dir"
print -r -- "exit=0"
