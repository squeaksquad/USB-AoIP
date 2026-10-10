#!/bin/bash
# Runs usb16x16-dante-owner on the Pi (OWNER_DESIGN.md): the Dante device stays
# up for as long as it runs, and the USB gadget is joined to it whenever a host
# is streaming. NO_USB=1 runs the network half alone (design step 4: silence
# out, capture discarded, the gadget never opened).
#
# As root, with Statime already running and the AES67 service stopped:
#   sudo ~/usb-16x16-work/dante-mode/run-owner.sh [SECONDS] [owner options...]
#   sudo NO_USB=1 ~/usb-16x16-work/dante-mode/run-owner.sh 3600
# SECONDS defaults to 3600; 0 runs until Ctrl+C. Unprivileged it refuses unless
# TRIAL=1, which runs without the memory lock and real-time priority (a smoke
# test, not a measurement). It starts and stops nothing but the owner.
# The settings below may also follow SECONDS as NAME=value arguments, for a
# sudo rule that does not pass the caller's environment:
#   sudo -n .../run-owner.sh 0 INFERNO_PLUGIN_DIR=.../plugins/xrun-option-retry1 --log-every 1
set -u
seconds="${1:-3600}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        NO_USB=*|OWNER_BIN=*|INFERNO_PLUGIN_DIR=*|INFERNO_CONFIG=*|RUST_LOG=*) export "$1"; shift ;;
        *) break ;;
    esac
done
base="$(cd "$(dirname "$0")" && pwd)"
# OWNER_BIN names another build kept beside the current one (an A/B of two binaries).
owner="$base/owner/${OWNER_BIN:-usb16x16-dante-owner}"
plugin_dir="${INFERNO_PLUGIN_DIR:-$base/plugins/xrun-option}"

refuse() { echo "REFUSED: $*"; exit 2; }
trial=""
mode=""
[ "${NO_USB:-0}" = 1 ] && mode="--no-usb"
if [ "$(id -u)" -ne 0 ]; then
    [ "${TRIAL:-0}" = 1 ] || refuse "run as root (memory lock and real-time priority), or TRIAL=1 for an unprivileged smoke test"
    trial="--no-mlock --no-rt"
fi
systemctl is-active --quiet usb16x16-aes67.service && refuse "usb16x16-aes67.service is active (it owns PTP on eth0)"
pgrep -x statime > /dev/null || refuse "Statime is not running"
[ -S /tmp/ptp-usrvclock ] || refuse "no Statime clock socket at /tmp/ptp-usrvclock"
for name in alsaloop inferno-probe usb16x16-dante-; do   # pgrep -x sees 15 characters of a name
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
    if [ -z "$mode" ] && grep -q UAC2Gadget /proc/asound/cards; then
        # The owner puts both back itself on a clean exit; do it again in case it was killed.
        amixer -q -c UAC2Gadget cset numid=1 1000000 2>/dev/null
        amixer -q -c UAC2Gadget cset numid=2 1000000 2>/dev/null
    fi
}
trap cleanup EXIT
{
    echo "START $stamp seconds=$seconds owner=$(sha256sum "$owner" | cut -c1-8) plugin=$(sha256sum "$plugin_dir/libasound_module_pcm_inferno.so" | cut -c1-8) config=$ALSA_CONFIG_PATH trial=${trial:-no} mode=${mode:-usb}"
} | tee "$log"
echo "log: $log"
"$owner" $mode --seconds "$seconds" --ppm-file "$XDG_STATE_HOME/usb16x16-dante-owner.ppm" $trial "$@" >> "$log" 2>&1 &
pid=$!
trap 'kill -INT $pid 2>/dev/null' INT TERM
wait "$pid"; rc=$?
# A signal interrupts the first wait; the owner then needs a moment to close.
if kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; fi
grep -E "^(SUMMARY|USBSUMMARY|FATAL)" "$log"
echo
echo "OWNER_EXIT $rc"
