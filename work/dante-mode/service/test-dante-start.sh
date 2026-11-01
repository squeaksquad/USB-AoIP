#!/bin/bash
# Test of usb16x16-dante-start's configuration handling; runs anywhere.
#   ./test-dante-start.sh             the wrapper as installed 2026-10-11
#   ./test-dante-start.sh transport   usb16x16-dante-start-transport: the same cases, which it must pass
#                                     unchanged with no transport file, and then its own
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
wrapper=$here/usb16x16-dante-start
[ "${1:-}" = transport ] && wrapper=$here/usb16x16-dante-start-transport
export USB16X16_DANTE_TRANSPORT=/nonexistent/transport.conf
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/dsp" "$work/elsewhere"
printf 'usb16x16-dsp 1\n' > "$work/dsp/a.dsp"
printf 'usb16x16-dsp 1\n' > "$work/elsewhere/b.dsp"
if command -v sha256sum >/dev/null 2>&1; then sha=$(sha256sum "$work/dsp/a.dsp" | cut -c1-64); else sha=$(shasum -a 256 "$work/dsp/a.dsp" | cut -c1-64); fi
failures=0
run() {   # the configuration text; sets $out and $code
  printf '%s' "$1" > "$work/owner.conf"
  out=$(USB16X16_DANTE_CONF="$work/owner.conf" USB16X16_DSP_DIR="$work/dsp" USB16X16_DANTE_RUN_DIR=/run/x \
        USB16X16_DANTE_STATE_DIR=/var/x USB16X16_DANTE_OWNER=/bin/owner "$wrapper" --print 2>&1 | tr '\n' ' ')
  code=${PIPESTATUS[0]}
}
expect() {   # name, wanted exit, wanted substring
  if [ "$code" != "$2" ] || [[ $out != *"$3"* ]]; then
    echo "FAIL: $1 (exit $code): $out"; failures=$((failures + 1))
  fi
}
base="/bin/owner --seconds 0 --ppm-file /var/x/usb16x16-dante-owner.ppm --log-every 60 "

rm -f "$work/owner.conf"
out=$(USB16X16_DANTE_CONF="$work/owner.conf" USB16X16_DANTE_STATE_DIR=/var/x USB16X16_DANTE_OWNER=/bin/owner "$wrapper" --print | tr '\n' ' '); code=$?
[ "$out" = "$base" ] || { echo "FAIL: no file is the old command line: $out"; failures=$((failures + 1)); }
run ""; [ "$out" = "$base" ] || { echo "FAIL: an empty file is the old command line: $out"; failures=$((failures + 1)); }
run $'# comment\n\nMETERS=1\n';                expect "meters" 0 "--log-every 60 --meter-file /run/x/meters.txt "
run $'METERS=0\n';                              [ "$out" = "$base" ] || { echo "FAIL: METERS=0: $out"; failures=$((failures + 1)); }
run "METERS=1"$'\n'"DSP_PRESET=$work/dsp/a.dsp"$'\n'"DSP_SHA256=$sha"$'\n'
expect "preset" 0 "--meter-file /run/x/meters.txt --dsp-preset $work/dsp/a.dsp "
[[ $out != *dsp-live* ]] || { echo "FAIL: no live file without DSP_LIVE=1"; failures=$((failures + 1)); }
run "DSP_PRESET=$work/dsp/a.dsp"$'\n'"DSP_SHA256=$sha"$'\n'"DSP_LIVE=1"   # no final newline
expect "live" 0 "--dsp-preset $work/dsp/a.dsp --dsp-live-file /run/x/dsp-live.dsp --dsp-live-status /run/x/dsp-live.status "

run "DSP_PRESET=$work/dsp/a.dsp"$'\n';                                          expect "preset without hash" 2 "needs DSP_SHA256"
run "DSP_PRESET=$work/dsp/a.dsp"$'\n'"DSP_SHA256=$(printf '0%.0s' {1..64})"$'\n'; expect "wrong hash" 2 "hashes to"
run "DSP_PRESET=$work/dsp/missing.dsp"$'\n'"DSP_SHA256=$sha"$'\n';              expect "missing preset" 2 "missing or unreadable"
run "DSP_PRESET=$work/elsewhere/b.dsp"$'\n'"DSP_SHA256=$sha"$'\n';              expect "preset elsewhere" 2 "directly under"
run "DSP_PRESET=$work/dsp/../elsewhere/b.dsp"$'\n'"DSP_SHA256=$sha"$'\n';       expect "preset by .." 2 "directly under"
run $'DSP_LIVE=1\n';                                                            expect "live without preset" 2 "needs DSP_PRESET"
run "DSP_SHA256=$sha"$'\n';                                                     expect "hash without preset" 2 "without DSP_PRESET"
run $'METERS=2\n';                                                              expect "bad METERS" 2 "METERS must be"
run $'DSP_SHA256=xyz\n';                                                        expect "bad hash text" 2 "64 hex digits"
run $'SOMETHING=1\n';                                                           expect "unknown key" 2 "unknown key"
run $'METERS=1; rm -rf /\n';                                                    expect "nothing is executed" 2 "METERS must be"
run $'export METERS=1\n';                                                       expect "not KEY=value" 2 "not KEY=value"
run $'RATE=48000\n';                                                            expect "rate" 0 "--log-every 60 --rate 48000 "
run "RATE=96000"$'\n'"METERS=1"$'\n'"DSP_PRESET=$work/dsp/a.dsp"$'\n'"DSP_SHA256=$sha"$'\n'
expect "rate with a preset" 0 "--log-every 60 --rate 96000 --meter-file /run/x/meters.txt --dsp-preset $work/dsp/a.dsp "
run $'RATE=32000\n';                                                            expect "not a Dante rate" 2 "RATE must be a Dante rate"
run $'RATE=48000 \n';                                                           expect "rate with trailing text" 2 "RATE must be a Dante rate"
if [ "${1:-}" = transport ]; then
  export USB16X16_DANTE_TRANSPORT=$work/transport.conf
  tr_run() { printf '%s' "$1" > "$work/transport.conf"; run "$2"; }
  tr_run $'# the return queue\nRX_QUEUE=96\n' ""
  [ "$out" = "${base}--rx-queue 96 " ] || { echo "FAIL: RX_QUEUE alone: $out"; failures=$((failures + 1)); }
  tr_run $'RX_QUEUE=96\n' $'METERS=1\n';      expect "queue with meters" 0 "--log-every 60 --rx-queue 96 --meter-file /run/x/meters.txt "
  tr_run "RX_QUEUE=112" "DSP_PRESET=$work/dsp/a.dsp"$'\n'"DSP_SHA256=$sha"$'\n'"DSP_LIVE=1"
  expect "queue with a live preset" 0 "--rx-queue 112 --dsp-preset $work/dsp/a.dsp --dsp-live-file /run/x/dsp-live.dsp "
  tr_run "" "";                                 [ "$out" = "$base" ] || { echo "FAIL: an empty transport file: $out"; failures=$((failures + 1)); }
  tr_run $'RX_QUEUE=95\n' "";                   expect "queue too small" 2 "RX_QUEUE must be"
  tr_run $'RX_QUEUE=4096\n' "";                 expect "queue too large" 2 "RX_QUEUE must be"
  tr_run $'RX_QUEUE=96; reboot\n' "";           expect "nothing is executed" 2 "RX_QUEUE must be"
  tr_run $'PERIOD=96\n' "";                     expect "unknown transport key" 2 "unknown key"
  tr_run $'PERIOD_96000=96\n' "";               expect "unknown per-rate key" 2 "unknown key PERIOD_96000"
  tr_run $'RATE_REQUESTS_96000=1\n' "";         expect "rate requests are not per rate" 2 "unknown key RATE_REQUESTS_96000"
  tr_run $'RX_QUEUE_32000=96\n' "";             expect "not a Dante rate suffix" 2 "unknown key RX_QUEUE_32000"
  tr_run $'METERS=1\n' "";                      expect "owner.conf keys do not belong there" 2 "unknown key"
  tr_run $'RX_QUEUE=96\n' $'RX_QUEUE=96\n';     expect "transport keys do not belong in owner.conf" 2 "unknown key"
  tr_run $'RX_QUEUE=96\n' $'RATE=96000\n';       expect "rate before the queue" 0 "--log-every 60 --rate 96000 --rx-queue 96 "
  tr_run $'RATE=96000\n' "";                      expect "the rate belongs in owner.conf" 2 "unknown key"
  tr_run $'RX_QUEUE=96\nRATE_REQUESTS=1\n' $'METERS=1\n'
  expect "rate requests" 0 "--rx-queue 96 --rate-request-file /run/x/rate-request --meter-file /run/x/meters.txt "
  tr_run $'RATE_REQUESTS=0\n' "";               [ "$out" = "$base" ] || { echo "FAIL: RATE_REQUESTS=0: $out"; failures=$((failures + 1)); }
  tr_run $'RATE_REQUESTS=yes\n' "";             expect "bad RATE_REQUESTS" 2 "RATE_REQUESTS must be"
  tr_run $'RX_QUEUE=96\nRATE_REQUESTS=1\nPRIME_DROP=24\nCAPTURE_DRAIN=1\n' $'METERS=1\n'
  expect "deterministic round trip" 0 "--rx-queue 96 --rate-request-file /run/x/rate-request --prime-drop 24 --capture-drain --meter-file /run/x/meters.txt "
  tr_run $'PRIME_DROP=0\n' "";                  expect "a drop of zero" 0 "--log-every 60 --prime-drop 0 "
  tr_run $'CAPTURE_DRAIN=0\n' "";               [ "$out" = "$base" ] || { echo "FAIL: CAPTURE_DRAIN=0: $out"; failures=$((failures + 1)); }
  tr_run $'PRIME_DROP=49\n' "";                 expect "drop too large" 2 "PRIME_DROP must be"
  tr_run $'PRIME_DROP=-1\n' "";                 expect "negative drop" 2 "PRIME_DROP must be"
  tr_run $'CAPTURE_DRAIN=yes\n' "";             expect "bad CAPTURE_DRAIN" 2 "CAPTURE_DRAIN must be"
  # The drop's limit is one block (2026-11-01): 48 for a plain or 48 kHz key, 96 for a 96 kHz one.
  tr_run $'PRIME_DROP_96000=96\n' $'RATE=96000\n';         expect "a drop of 96 at 96" 0 "--rate 96000 --prime-drop 96 "
  tr_run $'PRIME_DROP_96000=97\n' "";                      expect "96 kHz drop too large" 2 "PRIME_DROP_96000 must be a number of frames from 0 to 96"
  tr_run $'PRIME_DROP_48000=72\n' "";                      expect "48 kHz drop of 72" 2 "PRIME_DROP_48000 must be a number of frames from 0 to 48"
  tr_run $'PRIME_DROP=72\n' $'RATE=96000\n';               expect "a plain drop keeps 48, at 96 too" 2 "PRIME_DROP must be a number of frames from 0 to 48"
  # Per-rate keys (2026-10-31): the depths, and KEY_<rate> winning at its rate only.
  tr_run $'TX_LEAD=96\nBUFFER=1024\nGUARD=256\nRX_SLACK=96\nUSB_PERIOD=48\nUSB_BUFFER=480\n' ""
  expect "the depths" 0 "--log-every 60 --rx-slack 96 --buffer 1024 --tx-lead 96 --guard 256 --usb-period 48 --usb-buffer 480 "
  tr_run $'RX_QUEUE_96000=192\nRX_QUEUE=96\n' "";           expect "a 96 key at 48" 0 "--log-every 60 --rx-queue 96 "
  tr_run $'RX_QUEUE_96000=192\nRX_QUEUE=96\n' $'RATE=96000\n'; expect "a 96 key at 96, whatever the order" 0 "--rate 96000 --rx-queue 192 "
  tr_run $'RX_QUEUE_48000=112\n' "";                        expect "a 48000 key with no RATE=" 0 "--log-every 60 --rx-queue 112 "
  tr_run $'PRIME_DROP=28\nPRIME_DROP_96000=\n' $'RATE=96000\n'
  [ "$out" = "${base}--rate 96000 " ] || { echo "FAIL: an empty per-rate key turns the option off: $out"; failures=$((failures + 1)); }
  tr_run $'CAPTURE_DRAIN=1\nCAPTURE_DRAIN_96000=0\n' $'RATE=96000\n'
  [ "$out" = "${base}--rate 96000 " ] || { echo "FAIL: CAPTURE_DRAIN_96000=0: $out"; failures=$((failures + 1)); }
  tr_run $'RX_QUEUE_96000=4096\n' "";                       expect "a per-rate key is checked at any rate" 2 "RX_QUEUE must be"
  tr_run $'RX_QUEUE=\n' "";                                 expect "a plain key may not be empty" 2 "RX_QUEUE must be"
  tr_run $'BUFFER=100\n' "";                                expect "buffer too small" 2 "BUFFER must be"
  # The staged files: at 48 the installed command line exactly, at 96 arm A, at 44.1 the 48 figures.
  cp "$here/transport-rate96.conf" "$work/transport.conf"; run $'METERS=1\n'; at48_new=$out
  cp "$here/transport-ratepoll.conf" "$work/transport.conf"; run $'METERS=1\n'
  [ "$at48_new" = "$out" ] || { echo "FAIL: transport-rate96.conf changes the 48 kHz line: $at48_new"; failures=$((failures + 1)); }
  cp "$here/transport-rate96.conf" "$work/transport.conf"; run $'RATE=96000\nMETERS=1\n'
  [ "$out" = "${base}--rate 96000 --rx-queue 192 --rx-slack 192 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rate-request-file /run/x/rate-request --meter-file /run/x/meters.txt " ] ||
    { echo "FAIL: transport-rate96.conf at 96: $out"; failures=$((failures + 1)); }
  run $'RATE=44100\nMETERS=1\n'
  [ "$out" = "${base}--rate 44100 --rx-queue 96 --rate-request-file /run/x/rate-request --prime-drop 28 --capture-drain --meter-file /run/x/meters.txt " ] ||
    { echo "FAIL: transport-rate96.conf at 44.1: $out"; failures=$((failures + 1)); }
  # transport-rate96-drop.conf: the 48 line unchanged, 96 with the drop and the drain.
  cp "$here/transport-rate96-drop.conf" "$work/transport.conf"; run $'METERS=1\n'
  [ "$at48_new" = "$out" ] || { echo "FAIL: transport-rate96-drop.conf changes the 48 kHz line: $out"; failures=$((failures + 1)); }
  run $'RATE=96000\nMETERS=1\n'
  [ "$out" = "${base}--rate 96000 --rx-queue 192 --rx-slack 192 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rate-request-file /run/x/rate-request --prime-drop 48 --capture-drain --meter-file /run/x/meters.txt " ] ||
    { echo "FAIL: transport-rate96-drop.conf at 96: $out"; failures=$((failures + 1)); }
  # transport-rate96-drop96.conf (2026-11-01): the same, with a drop of 96 at 96.
  cp "$here/transport-rate96-drop96.conf" "$work/transport.conf"; run $'METERS=1\n'
  [ "$at48_new" = "$out" ] || { echo "FAIL: transport-rate96-drop96.conf changes the 48 kHz line: $out"; failures=$((failures + 1)); }
  run $'RATE=96000\nMETERS=1\n'
  [ "$out" = "${base}--rate 96000 --rx-queue 192 --rx-slack 192 --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960 --rate-request-file /run/x/rate-request --prime-drop 96 --capture-drain --meter-file /run/x/meters.txt " ] ||
    { echo "FAIL: transport-rate96-drop96.conf at 96: $out"; failures=$((failures + 1)); }
  run $'RATE=44100\nMETERS=1\n'
  case "$out" in *"--prime-drop 28 --capture-drain"*) ;; *) echo "FAIL: transport-rate96-drop96.conf at 44.1: $out"; failures=$((failures + 1)) ;; esac
fi
if [ "$failures" -eq 0 ]; then echo "test-dante-start: all passed"; else echo "test-dante-start: $failures FAILED"; exit 1; fi
