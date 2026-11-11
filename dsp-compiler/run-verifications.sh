#!/bin/zsh
# Run the three outstanding end-to-end engine verifications against the pinned
# CamillaDSP on the Pi: crossover magnitude/phase/summation, behaviour at and
# past full scale, and both headphone bus paths.
#
# File to file. No ALSA device is opened and no service is started. It does,
# however, refuse to run while usb16x16-aes67.service is up: these runs move
# tens of megabytes through the Pi's page cache, and the standing rule is that
# engine harnesses go between measurement sessions, not during one.
#
# The presets are compiled here on the Mac -- the Pi has no node -- and only
# the configurations, the harnesses and the results cross the link.
#
# Usage: run-verifications.sh [LABEL]
set -uo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
label=${1:-dsp-verify}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$repo_root/outputs/dsp-verify/${label}-${timestamp}"
pi_dir="/home/bdimaio/usb-16x16-work/dsp-verify"
camilladsp="/home/bdimaio/usb-16x16-work/camilladsp-v4.1.3/camilladsp"

pi() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 "$@" 2>/dev/null ||
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=audio-dev.local bdimaio@169.254.92.97 "$@"
}

print -r -- "=== DSP engine verification ($timestamp) -> $out_dir"

# ---------------------------------------------------------------- guard
state=$(pi 'echo "$(systemctl is-active usb16x16-aes67) $(pgrep -c camilladsp || true) $(wc -l < /run/usb16x16/recovers 2>/dev/null || echo 0)"')
service_state=${state%% *}
print -r -- "service: $service_state   camilladsp running: $(print -r -- "$state" | awk '{print $2}')   recovers so far: $(print -r -- "$state" | awk '{print $3}')"
if [[ "$service_state" == active ]]; then
  print -r -- "usb16x16-aes67.service is running. Stop it first:"
  print -r -- "  sudo systemctl stop usb16x16-aes67"
  print -r -- "exit=2"
  exit 2
fi

version=$(pi "$camilladsp --version")
print -r -- "engine: $version"
mkdir -p "$out_dir"

# ---------------------------------------------------------------- compile
compile="$repo_root/work/dsp-compiler/usb16x16-dsp-compile"
presets="$repo_root/work/dsp-compiler/verify-presets.mjs"
for name in crossover clip phones; do
  node "$presets" "$name" > "$out_dir/$name.json" || { print -r -- "exit=3"; exit 3; }
done
# Exit status 1 means an output can clip. The clip preset is meant to.
"$compile" "$out_dir/crossover.json" -o "$out_dir/crossover.yml" \
  --report "$out_dir/crossover-report.json" \
  --in "$pi_dir/xo-in.raw" --raw "$pi_dir/xo-out.raw" --format F64_LE
"$compile" "$out_dir/phones.json" -o "$out_dir/phones.yml" \
  --report "$out_dir/phones-report.json" \
  --in "$pi_dir/hp-in.raw" --raw "$pi_dir/hp-out.raw" --format S32_LE
"$compile" "$out_dir/clip.json" -o "$out_dir/clip-s32.yml" \
  --report "$out_dir/clip-report.json" \
  --in "$pi_dir/clip-in.raw" --raw "$pi_dir/clip-out.raw" --format S32_LE
"$compile" "$out_dir/clip.json" -o "$out_dir/clip-f64.yml" \
  --in "$pi_dir/clip-in.f64" --raw "$pi_dir/clip-out.f64" --format F64_LE

# ---------------------------------------------------------------- stage
pi "mkdir -p $pi_dir"
for file in crossover.yml phones.yml clip-s32.yml clip-f64.yml; do
  scp -q -o HostKeyAlias=audio-dev.local "$out_dir/$file" \
      bdimaio@192.168.1.201:"$pi_dir/" || { print -r -- "exit=4"; exit 4; }
done
for file in verify-crossover.py verify-clip.py verify-run.py; do
  scp -q -o HostKeyAlias=audio-dev.local "$repo_root/work/dsp-compiler/$file" \
      bdimaio@192.168.1.201:"$pi_dir/" || { print -r -- "exit=4"; exit 4; }
done

# The sample-format spelling the engine accepts was not recorded anywhere from
# the earlier runs, and the first attempt at these guessed it wrong: CamillaDSP
# 4.1.3 takes S16_LE, S24_4_RJ_LE, S24_4_LJ_LE, S24_3_LE, S32_LE, F32_LE and
# F64_LE. Confirm it here rather than discover it mid-measurement.
#
# --check opens the capture file as well as parsing the configuration, so the
# input has to exist for the check to be about the configuration at all.
print -r -- "--- config check"
pi "cd $pi_dir && touch xo-in.raw hp-in.raw clip-in.raw clip-in.f64"
for file in crossover.yml phones.yml clip-s32.yml clip-f64.yml; do
  result=$(pi "$camilladsp --check $pi_dir/$file 2>&1 | tail -3")
  print -r -- "$file: $result"
done

# ---------------------------------------------------------------- run
print -r -- "--- 1/3 crossover: magnitude, phase and the branch sum"
pi "cd $pi_dir && python3 verify-crossover.py crossover.yml --camilladsp $camilladsp \
  --in $pi_dir/xo-in.raw --out $pi_dir/xo-out.raw \
  --pair 1,2,80 --pair 3,4,80 --pair 5,6,80 --pair 7,8,200 \
  --order 4 --order 2 --order 2 --order 8" > "$out_dir/crossover-result.json"
print -r -- "  -> $(wc -c < "$out_dir/crossover-result.json") bytes"

print -r -- "--- 2/3 full scale: saturation, wrapping and bit transparency"
pi "cd $pi_dir && python3 verify-clip.py clip-s32.yml --camilladsp $camilladsp \
  --in $pi_dir/clip-in.raw --out $pi_dir/clip-out.raw \
  --float-config clip-f64.yml --float-in $pi_dir/clip-in.f64 --float-out $pi_dir/clip-out.f64 \
  --tone-frames 24000 --unity 1,1 --inverted 5,8 \
  --gain-path 2,2,6 --gain-path 3,3,12 --sum-path 4" > "$out_dir/clip-result.json"
print -r -- "  -> $(wc -c < "$out_dir/clip-result.json") bytes"

print -r -- "--- 3/3 headphones: pair and downmix"
pi "cd $pi_dir && python3 verify-run.py phones.yml --camilladsp $camilladsp \
  --in $pi_dir/hp-in.raw --out $pi_dir/hp-out.raw" > "$out_dir/phones-result.json"
print -r -- "  -> $(wc -c < "$out_dir/phones-result.json") bytes"

# ---------------------------------------------------------------- after
pi "rm -f $pi_dir/*.raw $pi_dir/*.f64"
after=$(pi 'echo "$(wc -l < /run/usb16x16/recovers 2>/dev/null || echo 0) $(systemctl is-active usb16x16-aes67)"')
print -r -- "recovers after: ${after%% *}   service: ${after##* }"
print -r -- "results in $out_dir"
print -r -- "exit=0"
