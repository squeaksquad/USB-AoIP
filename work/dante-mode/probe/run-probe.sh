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
# INFERNO_CONFIG and INFERNO_PLUGIN_DIR select another config or plugin build for
# one run (OWNER_DESIGN.md step 2: config/asound-inferno-freerun.conf with
# plugins/xrun-option); unset, the stock pair is used as before.
export ALSA_CONFIG_PATH="${INFERNO_CONFIG:-$base/config/asound-inferno.conf}"
export ALSA_PLUGIN_DIR="${INFERNO_PLUGIN_DIR:-$base/inferno/target/release}"
[ -f "$ALSA_CONFIG_PATH" ] || { echo "REFUSED: no config $ALSA_CONFIG_PATH"; exit 2; }
[ -f "$ALSA_PLUGIN_DIR/libasound_module_pcm_inferno.so" ] || { echo "REFUSED: no plugin in $ALSA_PLUGIN_DIR"; exit 2; }
export RUST_LOG="${RUST_LOG:-warn}"
export XDG_STATE_HOME="$base/state"
mkdir -p "$XDG_STATE_HOME"
# Log to tmpfs: a log on the SD card has produced a RECOVER lattice before.
log="/dev/shm/inferno-probe-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "log: $log"
echo "plugin: $(sha256sum "$ALSA_PLUGIN_DIR/libasound_module_pcm_inferno.so" | cut -c1-8) config: $ALSA_CONFIG_PATH" | tee "$log"
"$base/probe/inferno-probe" "$@" 2>&1 | tee -a "$log"
echo
echo "PROBE_EXIT ${PIPESTATUS[0]}"
