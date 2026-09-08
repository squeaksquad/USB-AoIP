#!/usr/bin/env python3
"""Phase 6: rebuild read-bar.sh-format reads from the Pi's journal when the
bridge log is gone (/run is tmpfs: a reboot erases bridge.log). The supervisor
forwards every bridge line to the journal, so the marker lines and the BRIDGE
lines survive there. One read per bridge process (a pid with a NEGOTIATED line
and at least --min-bridge BRIDGE lines): a "full" variant (all markers, the
last BRIDGE line) and, when the process has RECOVERs, a "prestorm" variant cut
at the first RECOVER, which is the trail gap-bar.py prices. Timestamps in the
journal are the Pi's local time (EDT), not UTC.

Get the journal on the Pi (read-only) and feed it here:
  ssh bdimaio@192.168.1.201 'journalctl -b -1 -u usb16x16-aes67.service --no-pager -o short-iso' > journal.txt
  journal-bar.py journal.txt reads/ && gap-bar.py reads/bar-journal-*.txt
"""
import os
import re
import sys

MARKERS = ("NEGOTIATED ", "ALIGN ", "PRIMED ", "RECOVER ", "DEPTHSTEP ", "ZERORUN ", "SUMMARY ")
PAT = re.compile(r"^(\S+) \S+ usb16x16-aes67\[(\d+)\]: (.*)$")


def main(journal, outdir, min_bridge=300):
    procs = {}
    for line in open(journal, encoding="utf-8", errors="replace"):
        m = PAT.match(line.rstrip("\n"))
        if m:
            ts, pid, msg = m.groups()
            procs.setdefault(pid, []).append((ts, msg))
    os.makedirs(outdir, exist_ok=True)
    for pid, ev in procs.items():
        msgs = [m for _, m in ev]
        if not any(m.startswith("NEGOTIATED") for m in msgs):
            continue
        if sum(m.startswith("BRIDGE ") for m in msgs) < min_bridge:
            continue
        rec = [i for i, m in enumerate(msgs) if m.startswith("RECOVER ")]
        tag = f"journal-{ev[0][0][:16].replace(':', '')}-pid{pid}"
        for variant, cut in (("full", None), ("prestorm", rec[0] if rec else None)):
            if variant == "prestorm" and cut is None:
                continue
            sel = msgs if cut is None else msgs[:cut]
            bridge = [i for i, m in enumerate(sel) if m.startswith("BRIDGE ")]
            end = ev[cut - 1][0] if cut else ev[-1][0]
            out = [
                f"# reconstructed from the journal (pid {pid}, bridge lines {ev[0][0]} .. {end}, variant {variant})",
                f"# BRIDGE lines {len(bridge)}, RECOVER {len(rec)} (first at {ev[rec[0]][0] if rec else '-'})",
            ]
            out += [m for m in sel if m.startswith(MARKERS)]
            if bridge:
                out.append(sel[bridge[-1]])
            path = os.path.join(outdir, f"bar-{tag}-{variant}.txt")
            with open(path, "w") as f:
                f.write("\n".join(out) + "\n")
            print("wrote", path, len(out), "lines")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
