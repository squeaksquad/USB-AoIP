#!/bin/bash
# Runs inferno-probe on the Pi against the staged plugin. Does not start Statime
# and does not touch any service: it refuses unless usb16x16-aes67.service is
# stopped and a Statime clock socket is present. Extra arguments go to the probe.
#
# Statime is started separately, as root, by the operator:
#   sudo ~/usb-16x16-work/dante-mode/statime/target/release/statime \
#        -c ~/usb-16x16-work/dante-mode/config/statime-first-run.toml
set -u
base="$HOME/usb-16x16-work/dante-mode"
if systemctl is-active --quiet usb16x16-aes67.service; then
    echo "REFUSED: usb16x16-aes67.service is active (it owns PTP on eth0)"; exit 2
fi
if [ ! -S /tmp/ptp-usrvclock ]; then
    echo "REFUSED: no Statime clock socket at /tmp/ptp-usrvclock"; exit 2
fi
export ALSA_CONFIG_PATH="$base/config/asound-inferno.conf"
export ALSA_PLUGIN_DIR="$base/inferno/target/release"
export RUST_LOG="${RUST_LOG:-warn}"
export XDG_STATE_HOME="$base/state"
mkdir -p "$XDG_STATE_HOME"
# Log to tmpfs: a log on the SD card has produced a RECOVER lattice before.
log="/dev/shm/inferno-probe-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "log: $log"
"$base/probe/inferno-probe" "$@" 2>&1 | tee "$log"
echo
echo "PROBE_EXIT ${PIPESTATUS[0]}"
