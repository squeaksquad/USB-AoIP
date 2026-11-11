#!/bin/sh
set -u

section() {
    printf '\n## %s\n' "$1"
}

run() {
    printf '\n$ %s\n' "$*"
    "$@" 2>&1 || printf '[exit %s]\n' "$?"
}

section "Identity and operating system"
run date --iso-8601=seconds
run hostnamectl
run uname -a
run cat /etc/os-release
run uptime

section "USB gadget invariant"
run systemctl is-enabled usb-16x16.service
run systemctl is-active usb-16x16.service
run systemctl show usb-16x16.service -p FragmentPath -p ExecStart -p ActiveEnterTimestamp
run modinfo -n usb_f_uac2
run cat /sys/class/udc/1000480000.usb/state
run cat /sys/class/udc/1000480000.usb/current_speed
run find /sys/kernel/config/usb_gadget/studio_audio -maxdepth 3 -type l -ls

section "ALSA inventory"
run cat /proc/asound/cards
run cat /proc/asound/devices
run cat /proc/asound/pcm
run aplay -l
run arecord -l
run aplay -L
run arecord -L
for pcm in /proc/asound/card*/pcm*/sub*/info /proc/asound/card*/pcm*/sub*/hw_params /proc/asound/card*/pcm*/sub*/status; do
    if [ -r "$pcm" ]; then
        run cat "$pcm"
    fi
done

section "Network inventory"
run ip -brief link
run ip -brief address
run ip route show table all
for iface_path in /sys/class/net/*; do
    iface=${iface_path##*/}
    [ "$iface" = lo ] && continue
    run ethtool -i "$iface"
    run ethtool -T "$iface"
    run ethtool "$iface"
done
run find /dev -maxdepth 1 -name 'ptp*' -ls

section "Clock and scheduling constraints"
run cat /sys/devices/system/clocksource/clocksource0/current_clocksource
run cat /sys/devices/system/clocksource/clocksource0/available_clocksource
for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    [ -r "$governor" ] && run cat "$governor"
done
run sysctl kernel.sched_rt_runtime_us
run sysctl vm.swappiness
run ps -eo pid,cls,rtprio,pri,ni,comm,args

section "Relevant packages"
run dpkg-query -W '-f=${binary:Package}\t${Version}\t${db:Status-Abbrev}\n'

section "Relevant services"
run systemctl list-unit-files --no-pager
run systemctl list-units --type=service --state=running --no-pager
run systemctl list-units --type=socket --state=running --no-pager

section "Available audio and timing commands"
for command_name in camilladsp camillagui alsaloop jackd pipewire pw-cli ptp4l phc2sys pmc ts2phc timemaster gst-launch-1.0 ffmpeg sapserver; do
    printf '%-16s' "$command_name"
    command -v "$command_name" 2>/dev/null || printf 'not installed\n'
done
