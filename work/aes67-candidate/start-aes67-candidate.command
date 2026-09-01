#!/bin/zsh

exec /usr/bin/ssh \
  -o BatchMode=yes \
  -o HostKeyAlias=audio-dev.local \
  bdimaio@192.168.1.201 \
  'USB16X16_CANDIDATE_SECONDS=180 sudo -n /usr/local/sbin/run-aes67-candidate-safe.sh'
