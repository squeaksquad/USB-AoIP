#!/bin/zsh

exec /usr/bin/ssh \
  -o BatchMode=yes \
  -o HostKeyAlias=audio-dev.local \
  bdimaio@192.168.1.201 \
  'USB16X16_RAVENNA_TEST_SECONDS=600 USB16X16_RAVENNA_SINK_DELAYS=48 sudo -n /usr/local/sbin/run-ravenna-latency-safe.sh 96'
