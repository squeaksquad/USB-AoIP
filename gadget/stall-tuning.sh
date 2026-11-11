#!/bin/bash
# Reversible, runtime-only levers for the 4-6 ms bridge stalls (Phase 6).
# Nothing here survives a reboot, and nothing touches the USB baseline, the
# module, the daemon, the bridge, or any file under /etc. Run on the Pi as
# root, one lever at a time, and judge each by the RECOVER count over hours:
#
#   sudo ./stall-tuning.sh status
#   sudo ./stall-tuning.sh governor performance   # lever 1
#   sudo ./stall-tuning.sh governor ondemand      # back to stock
#   sudo ./stall-tuning.sh irqs pin               # lever 2: USB gadget + eth0 -> CPU 1,
#                                                 #   everything else -> CPU 0
#   sudo ./stall-tuning.sh irqs unpin             # back to stock (all CPUs)
#
# The bridge audio thread was measured on CPUs 2-3 (SCHED_FIFO 90); the
# supervisor's mawk sits on CPU 1. Pinning the gadget and NIC interrupts to
# CPU 1 keeps their handlers off the audio thread's cores without isolating
# anything. Stock affinity for every IRQ on this Pi is 0-3.
set -euo pipefail

governor_path=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
usb_irq_pattern='1000480000.usb'
eth_irq_pattern='eth0'

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "run with sudo" >&2
    exit 2
  fi
}

irq_numbers() {
  # IRQ numbers whose /proc/interrupts line names the given pattern.
  awk -v pat="$1" '$0 ~ pat { sub(":", "", $1); print $1 }' /proc/interrupts
}

show_status() {
  echo "governor: $(cat "$governor_path")"
  echo "cpu0 cur/min/max kHz: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq) / $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
  local irq
  for irq in $(irq_numbers "$usb_irq_pattern") $(irq_numbers "$eth_irq_pattern"); do
    printf 'irq %s affinity: %s (%s)\n' "$irq" "$(cat "/proc/irq/$irq/smp_affinity_list")" \
      "$(awk -v n="$irq:" '$1 == n { print $NF }' /proc/interrupts)"
  done
  echo "default irq affinity: $(cat /proc/irq/default_smp_affinity)"
  echo "throttled: $(vcgencmd get_throttled 2>/dev/null || echo n/a)"
  echo "RECOVERs this boot: $(journalctl -u usb16x16-aes67.service -b --no-pager 2>/dev/null | grep -c RECOVER || true)"
}

set_governor() {
  need_root
  local wanted=$1 cpu
  case "$wanted" in performance|ondemand) ;; *) echo "governor must be performance or ondemand" >&2; exit 3 ;; esac
  for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    echo "$wanted" > "$cpu"
  done
  echo "governor set to $wanted on all CPUs (runtime only)"
}

set_irqs() {
  need_root
  local mode=$1 irq
  case "$mode" in
    pin)
      for irq in $(irq_numbers "$usb_irq_pattern") $(irq_numbers "$eth_irq_pattern"); do
        echo 1 > "/proc/irq/$irq/smp_affinity_list"
        echo "irq $irq -> CPU 1"
      done
      ;;
    unpin)
      for irq in $(irq_numbers "$usb_irq_pattern") $(irq_numbers "$eth_irq_pattern"); do
        echo 0-3 > "/proc/irq/$irq/smp_affinity_list"
        echo "irq $irq -> CPUs 0-3"
      done
      ;;
    *) echo "irqs must be pin or unpin" >&2; exit 3 ;;
  esac
}

case "${1:-status}" in
  status) show_status ;;
  governor) set_governor "${2:-}" ;;
  irqs) set_irqs "${2:-}" ;;
  *) echo "usage: $0 {status|governor performance|ondemand|irqs pin|unpin}" >&2; exit 2 ;;
esac
