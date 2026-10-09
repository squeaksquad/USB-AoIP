#!/bin/bash
# Dante prototype: USB gadget <-> Inferno through one alsaloop process.
#
# What it is for: a first end-to-end answer (the Mac's USB 16x16 routed in Dante
# Controller, audio both ways) and an upper bound on latency. What it is not: a
# candidate. alsaloop resamples to follow the two clocks (not bit transparent),
# adds its own buffering, and any xrun re-prepares the Inferno device, which
# costs about six seconds of audio (RESULTS.md). The USB pitch controls are read
# and left alone.
#
# Run on the Pi as root, with Statime already running and the AES67 service
# stopped:
#   sudo ~/usb-16x16-work/dante-mode/run-alsaloop-prototype.sh [SECONDS] [LATENCY_USEC] [INFERNO_LATENCY_NS]
# Defaults: 600 s, 20000 us per direction inside alsaloop, and the Inferno
# latencies as the config file has them (10 ms). INFERNO_LATENCY_NS sets both
# RX_LATENCY_NS and TX_LATENCY_NS for this run only, through a copy on tmpfs. PERIOD and BUFFER
# (frames, powers of two) can be set in the environment; unset, alsaloop chooses.
# Stop early with Ctrl+C. It starts and stops nothing but its own alsaloop.
set -u
seconds="${1:-600}"
latency_usec="${2:-20000}"
inferno_latency_ns="${3:-}"
period="${PERIOD:-}"
buffer="${BUFFER:-}"
base="$(cd "$(dirname "$0")" && pwd)"
gadget="plughw:CARD=UAC2Gadget,DEV=0"

refuse() { echo "REFUSED: $*"; exit 2; }
[ "$(id -u)" -eq 0 ] || refuse "run as root (the Inferno network threads need real-time priority)"
systemctl is-active --quiet usb16x16-aes67.service && refuse "usb16x16-aes67.service is active (it owns PTP on eth0 and the gadget PCMs)"
systemctl is-active --quiet usb-16x16.service || refuse "usb-16x16.service is not active"
pgrep -x statime > /dev/null || refuse "Statime is not running"
[ -S /tmp/ptp-usrvclock ] || refuse "no Statime clock socket at /tmp/ptp-usrvclock"
grep -q UAC2Gadget /proc/asound/cards || refuse "no UAC2Gadget sound card"
pgrep -x alsaloop > /dev/null && refuse "an alsaloop is already running"
pgrep -x inferno-probe > /dev/null && refuse "inferno-probe is running (one process per Inferno device)"
[ -f "$base/inferno/target/release/libasound_module_pcm_inferno.so" ] || refuse "plugin not built under $base"

export ALSA_CONFIG_PATH="$base/config/asound-inferno-loop.conf"
export ALSA_PLUGIN_DIR="$base/inferno/target/release"
export RUST_LOG="${RUST_LOG:-warn}"
export XDG_STATE_HOME="$base/state"
mkdir -p "$XDG_STATE_HOME"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -n "$inferno_latency_ns" ]; then
    # The two knobs are crossed in this Inferno revision, so both move together.
    tmpconf="/dev/shm/dante-asound-$stamp.conf"
    {
        echo "</usr/share/alsa/alsa.conf>"
        sed -E "s/^([[:space:]]*(RX|TX)_LATENCY_NS) .*/\\1 \"$inferno_latency_ns\"/" "$base/config/asound-inferno.conf"
    } > "$tmpconf"
    grep -c "LATENCY_NS \"$inferno_latency_ns\"" "$tmpconf" | grep -qx 2 || refuse "could not set the Inferno latencies in $tmpconf"
    export ALSA_CONFIG_PATH="$tmpconf"
fi
log="/dev/shm/dante-alsaloop-$stamp.log"     # tmpfs: an SD-card log has caused RECOVERs before
jobs="/dev/shm/dante-alsaloop-$stamp.jobs"
# -T -1 gives each direction its own thread. With both jobs on one thread alsaloop
# spins a core and the Dante -> USB direction stops after 960 frames (2026-10-09).
# Period and buffer are left to alsaloop unless set: this alsaloop rejects the
# short -E / -B options in a job file, so only the long names are used.
sizes=""
[ -n "$period" ] && sizes="$sizes --period $period"
[ -n "$buffer" ] && sizes="$sizes --buffer $buffer"
common="-T -1 -r 48000 -c 16 -f S32_LE -S samplerate -A sincfastest -t $latency_usec$sizes -v"
{
    echo "-C $gadget -P inferno $common"     # Mac USB out -> Dante transmit
    echo "-C inferno -P $gadget $common"     # Dante receive -> Mac USB in
} > "$jobs"

cleanup() {
    # State written as root would lock the unprivileged probe out of its own directory.
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":"$SUDO_USER" "$XDG_STATE_HOME" 2>/dev/null
    rm -f "$jobs" "${tmpconf:-}"
}
trap cleanup EXIT

{
    echo "START $stamp seconds=$seconds latency_usec=$latency_usec inferno_latency_ns=${inferno_latency_ns:-config} period=${period:-alsaloop} buffer=${buffer:-alsaloop}"
    echo "PITCH before: $(amixer -c UAC2Gadget cget numid=1 | tail -1 | tr -s ' ') | $(amixer -c UAC2Gadget cget numid=2 | tail -1 | tr -s ' ')"
    echo "UDC state: $(cat /sys/class/udc/*/state 2>/dev/null)"
    sed 's/^/JOB /' "$jobs"
} | tee "$log"
echo "log: $log"

timeout -k 5 -s INT "$seconds" alsaloop -g "$jobs" >> "$log" 2>&1 &
pid=$!
trap 'kill -INT $pid 2>/dev/null' INT TERM
sleep 5
if ! kill -0 "$pid" 2>/dev/null; then
    echo "alsaloop exited during startup; last lines:"; tail -n 20 "$log"
    echo "PROTOTYPE_EXIT 30"; exit 30
fi
echo "running: pid $pid, threads:"
ps -L -o tid,cls,rtprio,comm -p "$(pgrep -x alsaloop | head -1)" | tee -a "$log"
wait "$pid"; rc=$?
{
    echo "PITCH after: $(amixer -c UAC2Gadget cget numid=1 | tail -1 | tr -s ' ') | $(amixer -c UAC2Gadget cget numid=2 | tail -1 | tr -s ' ')"
    echo "END $(date -u +%Y%m%dT%H%M%SZ) alsaloop_rc=$rc"
} | tee -a "$log"
echo
echo "PROTOTYPE_EXIT $rc"
