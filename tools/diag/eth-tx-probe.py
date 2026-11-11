#!/usr/bin/env python3
"""Time one small UDP packet a millisecond through the Pi's eth0 transmit path, without root.

Each packet asks the kernel for two software timestamps (SO_TIMESTAMPING):
  SCHED  when it entered the queue discipline
  SND    when the driver took it for the controller
SND - SCHED is the time it waited above the driver. If the Dante flows' packets
are held because the driver has stopped its queue, these packets wait with them
and the wait shows here; if they are held inside the controller, SND stays
prompt and only the receiver sees them late.

One EVENT line when a packet waits 1 ms or more, or when two SND stamps are
2 ms or more apart; a MINUTE summary line; stop with SIGINT or SIGTERM.

  eth-tx-probe.py DEST_IP [PORT] > /dev/shm/eth-tx-probe.log
"""
import signal, socket, struct, sys, time

dest = (sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 50999)
SO_TIMESTAMPING = 37
FLAGS = (1 << 1) | (1 << 4) | (1 << 8) | (1 << 7) | (1 << 11)   # TX_SOFTWARE, SOFTWARE, TX_SCHED, OPT_ID, OPT_TSONLY
SCM_TSTAMP_SND, SCM_TSTAMP_SCHED = 0, 1
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPING, FLAGS)
s.connect(dest)
s.setblocking(False)
running = True
def stop(*_):
    global running
    running = False
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

def stamp(ns):
    return time.strftime("%H:%M:%S", time.gmtime(ns // 1_000_000_000)) + ".%03d" % (ns // 1_000_000 % 1000)

sched = {}
last_snd = None
sent = 0
minute_wait = 0
minute_gap = 0
minute_end = time.monotonic_ns() + 60_000_000_000
next_send = time.monotonic_ns()
payload = b"\0" * 32
print(f"START {stamp(time.time_ns())}Z dest={dest[0]}:{dest[1]}", flush=True)
while running:
    now = time.monotonic_ns()
    if now < next_send:
        time.sleep((next_send - now) / 1e9)
    next_send += 1_000_000
    if time.monotonic_ns() - next_send > 50_000_000:
        next_send = time.monotonic_ns()
    try:
        s.send(payload)
        sent += 1
    except OSError:
        pass
    while True:
        try:
            _, ancdata, _, _ = s.recvmsg(1, 512, socket.MSG_ERRQUEUE)
        except BlockingIOError:
            break
        except OSError:
            break
        when = kind = ident = None
        for level, ctype, data in ancdata:
            if level == socket.SOL_SOCKET and ctype == SO_TIMESTAMPING:
                sec, nsec = struct.unpack_from("qq", data, 0)
                when = sec * 1_000_000_000 + nsec
            elif level == socket.SOL_IP and ctype == socket.IP_RECVERR:
                _, origin, _, _, _, info, data_id = struct.unpack_from("IBBBBII", data, 0)
                if origin == 4:
                    kind, ident = info, data_id
        if when is None or kind is None:
            continue
        if kind == SCM_TSTAMP_SCHED:
            sched[ident] = when
            if len(sched) > 4096:
                sched.pop(next(iter(sched)))
        elif kind == SCM_TSTAMP_SND:
            wait = when - sched.pop(ident, when)
            gap = when - last_snd if last_snd is not None else 0
            last_snd = when
            minute_wait = max(minute_wait, wait)
            minute_gap = max(minute_gap, gap)
            if wait >= 1_000_000 or gap >= 2_000_000:
                print(f"EVENT {stamp(when)}Z id={ident} waited_above_driver_ms={wait / 1e6:.2f} since_previous_snd_ms={gap / 1e6:.2f}", flush=True)
    if time.monotonic_ns() >= minute_end:
        print(f"MINUTE {stamp(time.time_ns())}Z sent={sent} wait_max_ms={minute_wait / 1e6:.3f} snd_gap_max_ms={minute_gap / 1e6:.2f}", flush=True)
        sent = 0
        minute_wait = minute_gap = 0
        minute_end = time.monotonic_ns() + 60_000_000_000
print(f"STOP {stamp(time.time_ns())}Z", flush=True)
