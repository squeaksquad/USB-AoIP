#!/usr/bin/env python3
"""Print the page-migration and compaction counters of /proc/vmstat whenever one moves (polled at 20 Hz)."""
import time
KEYS = ("pgmigrate_success", "pgmigrate_fail", "compact_isolated", "compact_daemon_wake", "compact_stall",
        "compact_migrate_scanned", "unevictable_pgs_culled", "pgmajfault")
def read():
    out = {}
    with open("/proc/vmstat") as f:
        for line in f:
            k, v = line.split()
            if k in KEYS:
                out[k] = int(v)
    return out
last = read()
while True:
    time.sleep(0.05)
    now = read()
    moved = {k: now[k] - last[k] for k in KEYS if now[k] != last[k]}
    if moved:
        t = time.time()
        print(time.strftime("%H:%M:%S", time.gmtime(t)) + ".%03d " % (t * 1000 % 1000) + " ".join(f"{k}=+{v}" for k, v in moved.items()), flush=True)
    last = now
