#!/usr/bin/env python3
"""Watch the Dante owner's threads for a stall, without root and without touching it.

Once a second reads, for every thread of the unit's main process,
/proc/PID/task/TID/schedstat (nanoseconds on a CPU, nanoseconds runnable but
waiting for one, timeslices) and the CPU it last ran on, plus the per-CPU
irq and softirq time from /proc/stat. One line a second:

  S <UTC> own_ms=<this script's own interval> <thread>=<wait_us>/<run_us>/<slices>/<cpu> ... irq=<ms per cpu> sirq=<ms per cpu>

The owner logs its worst loop gap once a minute; this gives the second and
says which kind of stall it was. A late loop thread (the first, FIFO 79)
whose wait_us jumped by the size of the gap was runnable and kept off the
CPU (a higher priority thread, or interrupt work, which irq/sirq then
shows); one whose wait_us did not move was blocked or woken late, and its
slices for that second are short by the gap.

An E line follows each: the per-interrupt and per-softirq counts that moved
in that second, per CPU. It is marked <-- when a real-time thread waited
WAIT_US or more or the loop thread was switched out involuntarily. The
thread list is printed at each attach; a restart of the unit is followed.
About 60 MB a day; it stops itself at MAX_BYTES.

  owner-sched-watch.py [UNIT] > /dev/shm/owner-sched-watch.log
"""
import os, signal, subprocess, sys, time

unit = sys.argv[1] if len(sys.argv) > 1 else "usb16x16-dante"
WAIT_US = 1000
MAX_BYTES = 150_000_000
running = True
def stop(*_):
    global running
    running = False
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

def stamp():
    now = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + ".%03dZ" % (now * 1000 % 1000)

def read(path):
    with open(path) as f:
        return f.read()

def main_pid():
    out = subprocess.run(["systemctl", "show", unit, "-p", "MainPID", "--value"], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else 0

def threads(pid):
    """tid -> (label, realtime priority); the main thread is the owner's loop."""
    found = {}
    for name in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
        tid = int(name)
        fields = read(f"/proc/{pid}/task/{tid}/stat").rsplit(")", 1)[1].split()
        comm = read(f"/proc/{pid}/task/{tid}/comm").strip().replace(" ", "_")
        label = "loop" if tid == pid else f"{'own' if comm.startswith('usb16x16') else comm}.{tid}"
        found[tid] = (label, int(fields[37]))
    return found

def cpu_times():
    """Per-CPU (irq, softirq) jiffies."""
    return [(int(f[6]), int(f[7])) for f in (l.split() for l in read("/proc/stat").splitlines()) if f[0][:3] == "cpu" and f[0] != "cpu"]

def counters():
    """Every interrupt and softirq count, per CPU, keyed by its name."""
    table = {}
    for source in ("/proc/interrupts", "/proc/softirqs"):
        lines = read(source).splitlines()
        cpus = len(lines[0].split())
        for line in lines[1:]:
            parts = line.split()
            values = [int(v) for v in parts[1:1 + cpus] if v.isdigit()]
            if values:
                table[parts[0] + "_".join(parts[1 + cpus:])[-24:]] = values
    return table

def moved(before, after):
    out = []
    for name, values in after.items():
        delta = [a - b for a, b in zip(values, before.get(name, values))]
        if any(delta):
            out.append(f"{name}={','.join(map(str, delta))}")
    return " ".join(out)

tick = os.sysconf("SC_CLK_TCK")
pid = 0
names = {}
last = {}
written = 0
print(f"START {stamp()} unit={unit} wait_threshold_us={WAIT_US}", flush=True)
next_poll = time.monotonic()
last_poll = next_poll
while running:
    next_poll += 1.0
    time.sleep(max(0.0, next_poll - time.monotonic()))
    now = time.monotonic()
    own_ms = (now - last_poll) * 1000
    last_poll = now
    if now - next_poll > 5:
        next_poll = now
    try:
        if pid == 0:
            pid = main_pid()
            if pid == 0:
                continue
            names = threads(pid)
            last = {}
            print(f"THREADS {stamp()} pid={pid} " + " ".join(f"{label}:rt{rt}" for label, rt in names.values()), flush=True)
        sample = {}
        for tid in names:
            run, wait, slices = (int(v) for v in read(f"/proc/{pid}/task/{tid}/schedstat").split())
            cpu = read(f"/proc/{pid}/task/{tid}/stat").rsplit(")", 1)[1].split()[36]
            sample[tid] = (run, wait, slices, cpu)
        involuntary = int(read(f"/proc/{pid}/task/{pid}/status").rsplit("nonvoluntary_ctxt_switches:", 1)[1].split()[0])
        cpus = cpu_times()
        counts = counters()
    except (FileNotFoundError, ProcessLookupError, IndexError, ValueError):
        print(f"GONE {stamp()} pid={pid}", flush=True)
        pid = 0
        continue
    if last:
        text = []
        event = involuntary != last["involuntary"]
        for tid, (label, rt) in names.items():
            wait_us = (sample[tid][1] - last["sample"][tid][1]) // 1000
            run_us = (sample[tid][0] - last["sample"][tid][0]) // 1000
            text.append(f"{label}={wait_us}/{run_us}/{sample[tid][2] - last['sample'][tid][2]}/{sample[tid][3]}")
            if rt > 0 and wait_us >= WAIT_US:
                event = True
        irq = ",".join(str((a[0] - b[0]) * 1000 // tick) for a, b in zip(cpus, last["cpus"]))
        sirq = ",".join(str((a[1] - b[1]) * 1000 // tick) for a, b in zip(cpus, last["cpus"]))
        when = stamp()
        line = f"S {when} own_ms={own_ms:.1f} {' '.join(text)} irq={irq} sirq={sirq} invol={involuntary - last['involuntary']}"
        print(line, flush=True)
        written += len(line) + 1
        if written > MAX_BYTES:
            running = False
        detail = f"E {when} {moved(last['counts'], counts)}"
        print(detail + (" <--" if event else ""), flush=True)
        written += len(detail) + 1
    last = {"sample": sample, "involuntary": involuntary, "cpus": cpus, "counts": counts}
print(f"STOP {stamp()}", flush=True)
