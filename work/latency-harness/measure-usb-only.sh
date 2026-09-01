#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
app_binary="$script_dir/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency"
pi_target=${USB16X16_PI_TARGET:-bdimaio@192.168.1.201}
pi_alias=${USB16X16_PI_HOST_KEY_ALIAS:-audio-dev.local}
loopback_usec=${1:-80000}
coreaudio_frames=${2:-64}
impulse_count=${3:-20}
maximum_lag_ms=${4:-500}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_path="$repo_root/outputs/latency/usb-only-${loopback_usec}us-${coreaudio_frames}f-${timestamp}.json"
loop_log_path="$repo_root/outputs/latency/usb-only-${loopback_usec}us-${coreaudio_frames}f-${timestamp}-alsaloop.log"
remote_pid_file=/tmp/usb16x16-latency-alsaloop.pid
remote_log_file=/tmp/usb16x16-latency-alsaloop.log
started_loop=0

ssh_options=(
    -o BatchMode=yes
    -o "HostKeyAlias=$pi_alias"
    -o ConnectTimeout=5
)

cleanup() {
    if (( started_loop )); then
        ssh "${ssh_options[@]}" "$pi_target" \
            "if test -s '$remote_pid_file'; then
                loop_pid=\$(tr -cd '0-9' < '$remote_pid_file')
                if test -n \"\$loop_pid\" && kill -0 \"\$loop_pid\" 2>/dev/null; then
                    kill -INT \"\$loop_pid\"
                    sleep 1
                    if kill -0 \"\$loop_pid\" 2>/dev/null; then kill -TERM \"\$loop_pid\"; fi
                fi
                rm -f '$remote_pid_file'
            fi" || true
        scp -q "${ssh_options[@]}" "$pi_target:$remote_log_file" "$loop_log_path" || true
    fi
}
trap cleanup EXIT INT TERM

if [[ ! -x "$app_binary" ]]; then
    "$script_dir/build-app.sh"
fi

mkdir -p "$repo_root/outputs/latency"

ssh "${ssh_options[@]}" "$pi_target" \
    "set -eu
    if pgrep -x alsaloop >/dev/null; then
        echo 'refusing to start: alsaloop is already running' >&2
        exit 20
    fi
    rm -f '$remote_pid_file' '$remote_log_file'
    nohup alsaloop \
        -C hw:UAC2Gadget \
        -P hw:UAC2Gadget \
        -f S24_3LE \
        -c 16 \
        -r 48000 \
        -t '$loopback_usec' \
        -v \
        >'$remote_log_file' 2>&1 &
    echo \"\$!\" >'$remote_pid_file'"
started_loop=1
sleep 1

"$app_binary" measure \
    --device "USB 16x16" \
    --buffer-frames "$coreaudio_frames" \
    --input-channel 1 \
    --output-channel 1 \
    --impulses "$impulse_count" \
    --maximum-lag-ms "$maximum_lag_ms" \
    --output "$result_path" \
    >/dev/null

cleanup
started_loop=0
trap - EXIT INT TERM

ssh "${ssh_options[@]}" "$pi_target" \
    "test -z \"\$(pgrep -x alsaloop || true)\"
    test \"\$(cat /sys/class/udc/*/state)\" = configured
    test \"\$(cat /sys/class/udc/*/current_speed)\" = high-speed
    test \"\$(systemctl is-active usb-16x16.service)\" = active"

print -r -- "result=$result_path"
print -r -- "alsaloop_log=$loop_log_path"
plutil -extract correlation.statistics json -o - "$result_path"
