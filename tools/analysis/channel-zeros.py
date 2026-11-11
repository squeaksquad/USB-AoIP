#!/usr/bin/env python3
"""channel-zeros.py CAPTURE.pcap [--pi 169.254.92.97] [--min 4]: per channel, the runs
of zero samples in a capture of the Dante flows (2026-10-29, the rate-report soak).

diag/dante-pcap-zeros.py finds runs of zero bytes, so a hole on some channels of a
packet while its neighbours carry signal is invisible to it. This decodes each flow's
24-bit samples per channel, follows each channel across packets in timestamp order,
and prints every run of at least --min zero samples: direction, flow, channel in the
flow, start (Dante timestamp and capture time) and length. With noise on every channel
a real sample is never zero, so every run printed is audio that was not there.
Standard library only; reuses the pcap reader and frame parser of dante-pcap-zeros.py.
"""
import argparse
import collections
import importlib.util
import struct
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("pz", repo / "work/dante-mode/diag/dante-pcap-zeros.py")
pz = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pz)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("--pi", default="169.254.92.97")
    parser.add_argument("--min", type=int, default=4)
    parser.add_argument("--max", type=int, default=4800, help="longer runs are silence, not holes (100 ms at 48 kHz)")
    o = parser.parse_args()

    # per flow: channel count from (bytes, timestamp step); then per channel the open run
    state = {}
    runs = []
    totals = collections.Counter()
    for when, frame, cut in pz.packets(o.capture):
        parsed = pz.udp_payload(frame)
        if parsed is None or cut:
            continue
        src, dst, sport, dport, payload = parsed
        if len(payload) < 12 or payload[0] != 2:
            continue
        key = (src, sport, dst, dport)
        seconds, samples = struct.unpack(">II", payload[1:9])
        audio = payload[9:]
        s = state.get(key)
        if s is None:
            s = state[key] = {"last": None, "channels": None, "open": None, "first": (seconds, samples)}
        if s["channels"] is None:
            if s["last"] is None:
                s["last"] = (seconds, samples, len(audio))
                continue
            step = (samples - s["last"][1]) % 48000 or 48000
            frames = step
            s["channels"] = len(audio) // 3 // frames
            s["frames"] = frames
            s["open"] = [None] * s["channels"]   # (start stamp, start time, length)
        channels, frames = s["channels"], s["frames"]
        totals[key] += frames
        # Fast path: no run open and no three zero bytes anywhere, so no zero sample.
        if not any(s["open"]) and b"\0\0\0" not in audio:
            continue
        for f in range(frames):
            base = f * channels * 3
            for c in range(channels):
                b = audio[base + 3 * c: base + 3 * c + 3]
                run = s["open"][c]
                if b == b"\0\0\0":
                    if run is None:
                        s["open"][c] = [f"{seconds}+{samples + f}", when, 1]
                    else:
                        run[2] += 1
                elif run is not None:
                    if o.min <= run[2] <= o.max:
                        runs.append((key, c, *run))
                    s["open"][c] = None
    for key, s in state.items():
        direction = "Pi sends" if key[0] == o.pi else "Pi receives"
        print(f"{direction} {key[0]}:{key[1]} -> {key[2]}:{key[3]}: {s['channels']} channels, "
              f"{s['frames']} frames a packet, {totals[key]} frames")
    print(f"zero runs of {o.min}..{o.max} samples ending in signal: {len(runs)}")
    for key, c, stamp, when, length in sorted(runs, key=lambda r: r[3]):
        direction = "sends" if key[0] == o.pi else "receives"
        print(f"  {when:.6f} Pi {direction} flow :{key[1] if key[0] == o.pi else key[3]} ch{c + 1} stamp {stamp} length {length}")


if __name__ == "__main__":
    main()
