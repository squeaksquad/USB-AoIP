#!/usr/bin/env python3
"""Watch the Pi's eth0 transmit path for stalls, without root.

Polls two sysfs files about 2,000 times a second:
  queues/tx-0/byte_queue_limits/inflight   bytes handed to the driver and not yet completed
  statistics/tx_packets                    frames the controller has reported sent
With Dante flows running both normally move every poll. A stall inside the
controller shows as inflight climbing while tx_packets stands still; a delay
before the driver shows as tx_packets standing still with inflight at zero;
a delay after the Pi shows as nothing here at all.

One line per event (tx_packets still for 2 ms or more, or inflight above
INFLIGHT bytes), with UTC time, how long, the peak inflight, and the longest
gap between this script's own polls in the event (an event whose own gap is
as long as the stall is this script being descheduled, not a stall). A
summary line every 60 s. Stop with SIGINT or SIGTERM.

  eth-tx-watch.py [IFACE] > /dev/shm/eth-tx-watch.log
"""
import os, signal, sys, time

iface = sys.argv[1] if len(sys.argv) > 1 else "eth0"
INFLIGHT = 6000
STILL_NS = 2_000_000
base = f"/sys/class/net/{iface}"
fd_inflight = os.open(f"{base}/queues/tx-0/byte_queue_limits/inflight", os.O_RDONLY)
fd_packets = os.open(f"{base}/statistics/tx_packets", os.O_RDONLY)
running = True
def stop(*_):
    global running
    running = False
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

def stamp(ns):
    return time.strftime("%H:%M:%S", time.gmtime(ns // 1_000_000_000)) + ".%03d" % (ns // 1_000_000 % 1000)

now = time.monotonic_ns()
last_poll = now
last_packets = int(os.pread(fd_packets, 32, 0))
last_change = now
event_start = None
event_peak = 0
event_gap = 0
polls = 0
minute_peak = 0
minute_still = 0
minute_gap = 0
minute_end = now + 60_000_000_000
print(f"START {stamp(time.time_ns())}Z iface={iface} inflight_threshold={INFLIGHT} still_threshold_ms={STILL_NS / 1e6}", flush=True)
while running:
    time.sleep(0.0004)
    now = time.monotonic_ns()
    gap = now - last_poll
    last_poll = now
    inflight = int(os.pread(fd_inflight, 32, 0))
    packets = int(os.pread(fd_packets, 32, 0))
    polls += 1
    if packets != last_packets:
        last_packets = packets
        last_change = now
    still = now - last_change
    minute_peak = max(minute_peak, inflight)
    minute_still = max(minute_still, still)
    minute_gap = max(minute_gap, gap)
    active = still >= STILL_NS or inflight > INFLIGHT
    if active:
        if event_start is None:
            event_start = (time.time_ns(), now)
            event_peak = 0
            event_gap = 0
            event_still = 0
        event_peak = max(event_peak, inflight)
        event_gap = max(event_gap, gap)
        event_still = max(event_still, still)
    elif event_start is not None:
        print(f"EVENT {stamp(event_start[0])}Z lasted_ms={(now - event_start[1]) / 1e6:.2f} tx_still_ms={event_still / 1e6:.2f} "
              f"inflight_peak={event_peak} own_gap_ms={event_gap / 1e6:.2f}", flush=True)
        event_start = None
    if now >= minute_end:
        print(f"MINUTE {stamp(time.time_ns())}Z polls={polls} inflight_peak={minute_peak} tx_still_max_ms={minute_still / 1e6:.2f} "
              f"own_gap_max_ms={minute_gap / 1e6:.2f}", flush=True)
        polls = 0
        minute_peak = minute_still = minute_gap = 0
        minute_end = now + 60_000_000_000
print(f"STOP {stamp(time.time_ns())}Z", flush=True)
