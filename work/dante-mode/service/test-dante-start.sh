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
  tr_run $'TX_LEAD=96\n' "";                    expect "unknown transport key" 2 "unknown key"
  tr_run $'METERS=1\n' "";                      expect "owner.conf keys do not belong there" 2 "unknown key"
  tr_run $'RX_QUEUE=96\n' $'RX_QUEUE=96\n';     expect "transport keys do not belong in owner.conf" 2 "unknown key"
  tr_run $'RX_QUEUE=96\n' $'RATE=96000\n';       expect "rate before the queue" 0 "--log-every 60 --rate 96000 --rx-queue 96 "
  tr_run $'RATE=96000\n' "";                      expect "the rate belongs in owner.conf" 2 "unknown key"
  tr_run $'RX_QUEUE=96\nRATE_REQUESTS=1\n' $'METERS=1\n'
  expect "rate requests" 0 "--rx-queue 96 --rate-request-file /run/x/rate-request --meter-file /run/x/meters.txt "
  tr_run $'RATE_REQUESTS=0\n' "";               [ "$out" = "$base" ] || { echo "FAIL: RATE_REQUESTS=0: $out"; failures=$((failures + 1)); }
  tr_run $'RATE_REQUESTS=yes\n' "";             expect "bad RATE_REQUESTS" 2 "RATE_REQUESTS must be"
fi
if [ "$failures" -eq 0 ]; then echo "test-dante-start: all passed"; else echo "test-dante-start: $failures FAILED"; exit 1; fi
