#!/bin/zsh
# Read RTL Utility's own record of its last measurements, check each one was
# the standard reading (USB 16x16 both ways, output 1 to input 1, 48 kHz, the
# given buffer), and save the lines as evidence. RTL Utility appends one line
# per press of "Measure RTL" to its measurements log, whoever pressed it, so
# this reads the operator's readings and ones taken by driving the app alike.
#
#   read-rtl-log.sh [COUNT] [HARNESS_SAMPLES] [BUFFER]
#
# COUNT        how many of the newest lines to read (default 1)
# HARNESS_SAMPLES  the harness level on the same owner/bridge start; when
#              given, each reading is checked against harness + 188 at 32
#              frames (+ 252 at 64), the Mac-side cost measured 2026-09-02
# BUFFER       CoreAudio frames the reading must have been taken at (default 32)
#
# Before pressing Measure, the application log must show both sides opened on
# the device ("CoreAudio: Opened: USB 16x16" twice): choosing the input first
# and the output second is what gets that; the other order left the output on
# the laptop speakers with the menu still saying USB 16x16 (2026-10-10). The
# harness and RTL Utility never share the device.
set -uo pipefail
count=${1:-1}
harness=${2:-}
buffer=${3:-32}
log="$HOME/Library/Logs/RTL Utility/RTL Utility measurements log.txt"
app_log="$HOME/Library/Logs/RTL Utility/RTL Utility application log.txt"
repo_root=${0:A:h:h:h}
[[ -r "$log" ]] || { echo "REFUSED: no RTL Utility measurements log at $log"; exit 2; }
opened=$(grep 'CoreAudio: Opened:' "$app_log" 2>/dev/null | tail -2 | sort -u)
echo "devices open now: ${opened//$'\n'/ | }"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$repo_root/outputs/latency/rtl-utility-${buffer}f-${stamp}.txt"
failed=0
lines=$(grep '^"[0-9]' "$log" | tail -n "$count")
print -r -- "$lines" > "$out"
print -r -- "$lines" | while IFS= read -r line; do
  fields=("${(@s:, :)line}")
  when=${fields[1]//\"/}; device=${fields[3]//\"/}; channel=${fields[5]//\"/}
  rate=${fields[6]}; frames=${fields[8]}; reported=${fields[19]}
  samples=${fields[20]//\"/}; ms=${fields[21]//\"/}; level=${fields[22]}; correlation=${fields[24]}; valid=${fields[25]}
  utc=$(date -j -f '%d %b %Y %H:%M:%S' "$when" +%s 2>/dev/null); utc=$(date -u -r "${utc:-0}" +%H:%M:%SZ)
  verdict=ok
  [[ $device == "USB 16x16" && $channel == 1 && $rate == 48000 && $frames == $buffer ]] || verdict="NOT STANDARD (device/channel/rate/buffer)"
  [[ $samples == <-> && $valid == True ]] || verdict="NO READING"
  if [[ $verdict == ok && -n $harness ]]; then
    cost=$(( buffer == 64 ? 252 : 188 ))
    (( samples == harness + cost )) && verdict="ok, harness $harness + $cost" || verdict="OFF harness + $cost by $(( samples - harness - cost ))"
  fi
  [[ $verdict == ok* ]] || failed=1
  echo "$when local ($utc)  $device ch $channel  ${frames}f  reported $reported  RTL $samples samples  $ms ms  return $level dB  correlation $correlation  [$verdict]"
done
echo "saved: ${out#$repo_root/}"
exit $failed
