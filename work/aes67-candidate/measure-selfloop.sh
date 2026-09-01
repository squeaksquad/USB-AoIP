#!/bin/zsh
set -euo pipefail

# Measures the complete round trip with the Pi subscribed to its own AES67
# transmit streams, so the Ferrofish is not in the path:
#
#   Pro Tools -> USB 16x16 -> Pi -> AES67 TX -> AES67 RX -> Pi -> USB 16x16 -> Pro Tools
#
# This is the bridge-only floor. Run the Ferrofish path afterwards with
# measure-aes67-roundtrip.sh to see what the Ferrofish adds.

script_dir=${0:A:h}

USB16X16_REMOTE_CANDIDATE=${USB16X16_REMOTE_CANDIDATE:-/usr/local/sbin/run-selfloop-candidate-safe.sh} \
USB16X16_REMOTE_READY_FILE=${USB16X16_REMOTE_READY_FILE:-/tmp/usb16x16-selfloop.ready} \
USB16X16_PATH_LABEL="AES67 self-loop (Pi subscribed to its own streams)" \
USB16X16_PATH_HINT="The Pi did not receive its own multicast. Check the eth0 multicast route and IGMP membership." \
    exec "$script_dir/measure-aes67-roundtrip.sh" "$@"
