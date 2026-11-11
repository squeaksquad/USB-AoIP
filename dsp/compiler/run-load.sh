#!/bin/zsh
# Measure what the DSP configurations cost the Pi, file to file.
#
# Step 4 has to answer this before any of its architecture matters: can the Pi
# carry 16 outputs of PEQ plus the crossovers at 48 kHz, and with how much
# margin. Four points, chosen to separate the two questions that answer it:
#
#   default @ 1024   routing and crossovers alone, every band flat
#   loaded  @ 1024   the acceptance case: 16 outputs, 256 bands, 26 crossovers
#   loaded  @ 256    the same work in smaller chunks
#   loaded  @ 48     and in the quantum the bridge already works in
#
# default against loaded prices the PEQ. The chunksize sweep prices the
# per-chunk overhead, which is what a low-latency service would be paying.
#
# No ALSA device is opened. It refuses to run while usb16x16-aes67.service is
# up: this moves tens of megabytes through the page cache and saturates a core.
#
# Usage: run-load.sh [LABEL]
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
label=${1:-load}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$repo_root/outputs/dsp-verify/${label}-${timestamp}"
pi_dir="/home/bdimaio/usb-16x16-work/dsp-verify"
camilladsp="/home/bdimaio/usb-16x16-work/camilladsp-v4.1.3/camilladsp"

pi() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 "$@" 2>/dev/null ||
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@169.254.92.97 "$@"
}

print -r -- "=== DSP load ($timestamp)"
state=$(pi 'echo "$(systemctl is-active usb16x16-aes67) $(wc -l < /run/usb16x16/recovers 2>/dev/null || echo 0)"')
if [[ "${state%% *}" == active ]]; then
  print -r -- "usb16x16-aes67.service is running. Stop it first:"
  print -r -- "  sudo systemctl stop usb16x16-aes67"
  print -r -- "exit=2"
  exit 2
fi
print -r -- "service: ${state%% *}   recovers so far: ${state##* }"
mkdir -p "$out_dir"

compile="$repo_root/work/dsp-compiler/usb16x16-dsp-compile"
presets="$repo_root/work/dsp-compiler/verify-presets.mjs"
for name in default loaded; do
  node "$presets" "$name" > "$out_dir/$name.json" || { print -r -- "exit=3"; exit 3; }
done

# One input file per duration, shared by every point: generating them in Python
# costs more than the engine takes to process them.
points=(default:1024 loaded:1024 loaded:256 loaded:48)
for point in $points; do
  name=${point%%:*}; chunk=${point##*:}
  for span in short long; do
    "$compile" "$out_dir/$name.json" -o "$out_dir/$name-$chunk-$span.yml" \
      --in "$pi_dir/load-$span.raw" --raw "$pi_dir/load-$span-out.raw" \
      --format S32_LE --chunksize "$chunk" >/dev/null 2>&1
  done
done

pi "mkdir -p $pi_dir"
scp -q -o HostKeyAlias=audio-dev.local "$repo_root/work/dsp-compiler/measure-load.py" \
    bdimaio@192.168.1.201:"$pi_dir/" || { print -r -- "exit=4"; exit 4; }
for file in "$out_dir"/*-*-{short,long}.yml; do
  scp -q -o HostKeyAlias=audio-dev.local "$file" \
      bdimaio@192.168.1.201:"$pi_dir/" || { print -r -- "exit=4"; exit 4; }
done

for point in $points; do
  name=${point%%:*}; chunk=${point##*:}
  print -r -- "--- $name, chunksize $chunk"
  pi "cd $pi_dir && python3 measure-load.py $name-$chunk-short.yml $name-$chunk-long.yml \
    --camilladsp $camilladsp --label '$name@$chunk' --keep-input \
    --short-in $pi_dir/load-short.raw --short-out $pi_dir/load-short-out.raw \
    --long-in $pi_dir/load-long.raw --long-out $pi_dir/load-long-out.raw" \
    > "$out_dir/$name-$chunk.json"
  python3 -c "
import json, sys
try: r = json.load(open('$out_dir/$name-$chunk.json'))
except Exception: print('  (no result)'); sys.exit()
m = r['marginal']
print('  cores needed %.4f   realtime x%.1f (cpu)   x%.1f (wall)   temp %.1f -> %.1f C'
      % (m['coresNeeded'], m['realtimeFactorCpu'], m['realtimeFactorWall'],
         r['before']['tempC'], r['after']['tempC']))"
done

pi "rm -f $pi_dir/load-*.raw"
after=$(pi 'echo "$(wc -l < /run/usb16x16/recovers 2>/dev/null || echo 0) $(systemctl is-active usb16x16-aes67)"')
print -r -- "recovers after: ${after%% *}   service: ${after##* }"
print -r -- "results in $out_dir"
print -r -- "exit=0"
