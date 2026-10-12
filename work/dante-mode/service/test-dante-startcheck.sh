#!/bin/bash
# Tests for usb16x16-dante-startcheck: the classification against the rates
# measured on 2026-10-12, and the whole script against a stand-in ethtool and
# systemctl. Runs anywhere bash does (the Mac included); touches nothing.
#
#   ./test-dante-startcheck.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
check=$here/usb16x16-dante-startcheck
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
expect() {   # name, wanted, got
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: wanted '$2', got '$3'"; failures=$((failures + 1)); fi
}

# Rates read on the Pi, frames a second.
expect "whole at 16 frames a packet (6005)"       whole "$("$check" --classify 6005)"
expect "one flow losing at 16 frames (5191)"      short "$("$check" --classify 5191)"
expect "one flow losing at 16 frames (5195)"      short "$("$check" --classify 5195)"
expect "whole at 4 frames a packet (24010)"       whole "$("$check" --classify 24010)"
expect "one flow losing at 4 frames (23184)"      short "$("$check" --classify 23184)"
expect "two flows losing at 16 frames (4386)"     short "$("$check" --classify 4386)"
expect "whole at 32 frames a packet (3003)"       whole "$("$check" --classify 3003)"
expect "just under a multiple (5990)"             whole "$("$check" --classify 5990)"
expect "no flows (25)"                            idle  "$("$check" --classify 25)"
expect "chatter only (400)"                       idle  "$("$check" --classify 400)"

# A stand-in ethtool whose counter advances by RATE a second of wall time, and
# a systemctl that records what it was asked.
cat > "$work/ethtool" <<'EOF'
#!/bin/bash
rate=$(cat "$FAKE_DIR/rate")
now=$(date +%s)
echo "     rx_64_byte_frames: $(( now * 17 ))"
echo "     rx_128_255_byte_frames: $(( now * 3 ))"
echo "     rx_256_511_byte_frames: $(( now * (rate - 3) ))"
EOF
cat > "$work/systemctl" <<'EOF'
#!/bin/bash
case "$*" in
  "is-active usb16x16-dante.service") cat "$FAKE_DIR/active" ;;
  "show -p InvocationID --value usb16x16-dante.service") cat "$FAKE_DIR/invocation" ;;
  *) echo "$*" >> "$FAKE_DIR/asked" ;;
esac
EOF
chmod +x "$work/ethtool" "$work/systemctl"
run() {   # rate, extra arguments...: the script's output, with one-second windows and no settling
  local rate=$1; shift
  echo "$rate" > "$work/rate"
  FAKE_DIR=$work USB16X16_STARTCHECK_ETHTOOL=$work/ethtool USB16X16_STARTCHECK_SYSTEMCTL=$work/systemctl \
    USB16X16_STARTCHECK_DIR=$work/state USB16X16_STARTCHECK_WINDOW=1 USB16X16_STARTCHECK_SETTLE=0 \
    USB16X16_STARTCHECK_FLOWS=3 "$check" "$@" 2>&1
}
fresh() { rm -rf "$work/state" "$work/asked"; echo active > "$work/active"; echo abc123 > "$work/invocation"; }

fresh; out=$(run 6005)
expect "a whole start is left alone"              ""   "$(cat "$work/asked" 2>/dev/null)"
expect "a whole start says so"                    1    "$(echo "$out" | grep -c "startcheck: whole")"
expect "a whole start's status"                   ok   "$(sed -E 's/^state=([a-z-]+) .*/\1/' "$work/state/status")"

fresh; out=$(run 5193)
expect "a short start is restarted" \
  "reset-failed usb16x16-dante.service|--no-block restart usb16x16-dante.service" "$(paste -sd'|' "$work/asked")"
expect "a short start counts one restart"         1    "$(cut -d' ' -f1 "$work/state/restarts")"

out=$(run 5193); out=$(run 5193); out=$(run 5193)
expect "four restarts are counted"                4    "$(cut -d' ' -f1 "$work/state/restarts")"
rm -f "$work/asked"; out=$(run 5193)
expect "the fifth short start is not restarted"   ""   "$(cat "$work/asked" 2>/dev/null)"
expect "and it says it gave up"                   1    "$(echo "$out" | grep -c "giving up")"

out=$(run 6005)
expect "a whole start clears the count"           no   "$([ -e "$work/state/restarts" ] && echo yes || echo no)"

fresh; out=$(run 5193 --dry-run)
expect "a dry run restarts nothing"               ""   "$(cat "$work/asked" 2>/dev/null)"
expect "a dry run says what it would do"          1    "$(echo "$out" | grep -c "would restart")"
expect "a dry run writes no state"                no   "$([ -e "$work/state" ] && echo yes || echo no)"

fresh; out=$(run 20)
expect "no audio: nothing asked"                  ""   "$(cat "$work/asked" 2>/dev/null)"
expect "no audio: says so"                        1    "$(echo "$out" | grep -c "nothing to judge")"

fresh; echo inactive > "$work/active"; out=$(run 5193)
expect "an inactive endpoint is not judged"       ""   "$(cat "$work/asked" 2>/dev/null)"

# The endpoint restarted by someone else during the reading: leave it to the new start's check.
fresh; ( sleep 1; echo other456 > "$work/invocation" ) & out=$(run 5193); wait
expect "a start it did not measure is left alone" ""   "$(cat "$work/asked" 2>/dev/null)"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; exit 1; fi
