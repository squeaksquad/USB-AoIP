#!/usr/bin/env python3
"""watch-chanhole.py OWNER_LOG OUT_DIR: the trigger of the 96 kHz catch (2026-10-31).

Follows the owner's log for CHANHOLE lines (owner --chan-holes 8). Lines with the
same wall stamp are one event. An event on fewer than all 8 loop channels (the
2026-10-29 shape: 32 or 64 frames on ch3, 5, 6, 8) stops the capture 2 s later
(`sudo -n usb16x16-dante-catch stop`) and the watcher exits; an event on all 8 is
the outgoing side or a stream edge (the 48 kHz re-link of 04:34 that day) and is
logged and passed over. Runs as bdimaio on the Pi.
"""
import subprocess
import sys
import time
from pathlib import Path

log, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
record = open(out / "trigger.txt", "a", buffering=1)


def stamp():
    return time.strftime("%H:%M:%S", time.gmtime()) + f".{int(time.time() % 1 * 1000):03d}"


def stop(reason):
    record.write(f"{stamp()} {reason}; stopping the capture in 2 s\n")
    time.sleep(2)
    result = subprocess.run(["sudo", "-n", "/usr/local/sbin/usb16x16-dante-catch", "stop"], capture_output=True, text=True)
    record.write(f"{stamp()} {result.stdout.strip()} {result.stderr.strip()}\n")


def judge(group):
    """True when this event fired the trigger."""
    channels = sorted(int(g["ch"]) for g in group)
    frames = sorted({int(g["frames"]) for g in group})
    summary = (f"CHANHOLE wall={group[0]['wall']} ch={','.join(map(str, channels))} "
               f"frames={','.join(map(str, frames))} frame={group[0]['frame']}")
    if len(channels) < 8:
        stop(f"TRIGGER {summary}")
        return True
    record.write(f"{stamp()} passed over (all 8 channels) {summary}\n")
    return False


with open(log) as handle:
    handle.seek(0, 2)
    record.write(f"{stamp()} watching {log}\n")
    group, last = [], 0.0
    while True:
        line = handle.readline()
        if line.startswith("CHANHOLE "):
            fields = dict(part.split("=", 1) for part in line.split()[1:] if "=" in part)
            if group and fields["wall"] != group[0]["wall"]:
                if judge(group):
                    break
                group = []
            group.append(fields)
            last = time.monotonic()
            continue
        if not line:
            time.sleep(0.05)
        if group and time.monotonic() - last >= 0.3:
            if judge(group):
                break
            group = []
