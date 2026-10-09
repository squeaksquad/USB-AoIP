#!/bin/bash
# Runs usb16x16-dante-owner on the Pi (OWNER_DESIGN.md). Step 4: the network half
# only (--no-usb): the Dante device stays up, sends silence and discards what it
# receives; the gadget is not opened.
#
# As root, with Statime already running and the AES67 service stopped:
#   sudo ~/usb-16x16-work/dante-mode/run-owner.sh [SECONDS] [owner options...]
# SECONDS defaults to 3600; 0 runs until Ctrl+C. Unprivileged it refuses unless
# TRIAL=1, which runs without the memory lock and real-time priority (a smoke
# test, not a measurement). It starts and stops nothing but the owner.
set -u
seconds="${1:-3600}"
[ $# -gt 0 ] && shift
base="$(cd "$(dirname "$0")" && pwd)"
owner="$base/owner/usb16x16-dante-owner"
plugin_dir="${INFERNO_PLUGIN_DIR:-$base/plugins/xrun-option}"

refuse() { echo "REFUSED: $*"; exit 2; }
trial=""
if [ "$(id -u)" -ne 0 ]; then
    [ "${TRIAL:-0}" = 1 ] || refuse "run as root (memory lock and real-time priority), or TRIAL=1 for an unprivileged smoke test"
    trial="--no-mlock --no-rt"
fi
systemctl is-active --quiet usb16x16-aes67.service && refuse "usb16x16-aes67.service is active (it owns PTP on eth0)"
pgrep -x statime > /dev/null || refuse "Statime is not running"
[ -S /tmp/ptp-usrvclock ] || refuse "no Statime clock socket at /tmp/ptp-usrvclock"
for name in alsaloop inferno-probe usb16x16-dante-owner; do
    pgrep -x "$name" > /dev/null && refuse "$name is running (one process per Inferno device)"
done
[ -x "$owner" ] || refuse "owner not built at $owner"
[ -f "$plugin_dir/libasound_module_pcm_inferno.so" ] || refuse "no plugin in $plugin_dir"

export ALSA_CONFIG_PATH="${INFERNO_CONFIG:-$base/config/asound-inferno-owner.conf}"
export ALSA_PLUGIN_DIR="$plugin_dir"
export RUST_LOG="${RUST_LOG:-warn}"
export XDG_STATE_HOME="$base/state"
mkdir -p "$XDG_STATE_HOME"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="/dev/shm/dante-owner-$stamp.log"     # tmpfs: an SD-card log has caused RECOVERs before
cleanup() {
    # State written as root would lock the unprivileged probe out of its own directory.
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":"$SUDO_USER" "$XDG_STATE_HOME" "$log" 2>/dev/null
}
trap cleanup EXIT
{
    echo "START $stamp seconds=$seconds owner=$(sha256sum "$owner" | cut -c1-8) plugin=$(sha256sum "$plugin_dir/libasound_module_pcm_inferno.so" | cut -c1-8) config=$ALSA_CONFIG_PATH trial=${trial:-no}"
} | tee "$log"
echo "log: $log"
"$owner" --no-usb --seconds "$seconds" $trial "$@" >> "$log" 2>&1 &
pid=$!
trap 'kill -INT $pid 2>/dev/null' INT TERM
wait "$pid"; rc=$?
# A signal interrupts the first wait; the owner then needs a moment to close.
if kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; fi
grep -E "^(SUMMARY|FATAL)" "$log"
echo
echo "OWNER_EXIT $rc"
