#!/bin/bash
# Dante stage 2 build: Statime fork, then the Inferno ALSA plugin. Service must be stopped.
. "$HOME/.cargo/env"
cd "$HOME/usb-16x16-work/dante-mode"
if systemctl is-active --quiet usb16x16-aes67.service; then echo "REFUSED service active"; echo "BUILD_EXIT 99"; exit 99; fi
date -u +"start %FT%TZ"
( cd statime && cargo build --release --locked -j2 -p statime-linux ) ; s=$?
date -u +"statime rc=$s %FT%TZ"
( cd inferno && cargo build --release --locked -j2 -p alsa_pcm_inferno ) ; i=$?
date -u +"inferno rc=$i %FT%TZ"
echo
echo "BUILD_EXIT $((s*10+i))"
