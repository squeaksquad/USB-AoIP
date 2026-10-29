#!/usr/bin/env python3
"""slip-wire.py RING_FILE... [--at WALL]: the bitexact sequence in the Pulse's flows to the Pi, for the
96 kHz misplaced blocks (2026-10-29). The files of a tcpdump ring are read in time order. For every
looped channel each break is named as `bitexact` and the owner's --seq-check name it (dropped N,
repeated N, other), with the packet's capture time (the Pi's clock, the same as the owner's SEQ lines),
its Dante stamp and the sample's place in the packet. Each packet's stamp is also checked against the
one before (a gap, a repeat, out of order). With --at, the packets within 5 ms of WALL are listed with
their stamps and the first code of channel 1, to read which side shifted the block: audio misplaced
inside packets whose stamps run on evenly was sent that way; audio continuous on the wire, against a
shift in what Inferno delivered, was misplaced by Inferno's receive. Standard library only.
"""
import argparse
import importlib.util
import struct
from pathlib import Path

repo = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("pz", repo / "work/dante-mode/diag/dante-pcap-zeros.py")
pz = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pz)

MASK, MULT = 0xFFFFFF, 1664525
INV = MULT
for _ in range(5):
    INV = (INV * (2 - MULT * INV)) & 0xFFFFFFFF
INV &= MASK


def inc(ch): return (1013904223 + 2 * ch) & MASK
def nxt(code, ch): return (code * MULT + inc(ch)) & MASK
def prv(code, ch): return ((code - inc(ch)) * INV) & MASK


def classify(received, last, ch, search=1024):
    forward, back = nxt(last, ch), last
    for n in range(1, search + 1):
        if received == back: return f"repeated {n}"
        forward = nxt(forward, ch)
        if received == forward: return f"dropped {n}"
        back = prv(back, ch)
    return "other"


def first_time(path):
    for when, _, _ in pz.packets(path):
        return when
    return float("inf")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--pi", default="169.254.92.97")
    ap.add_argument("--rate", type=int, default=96000)
    ap.add_argument("--at", type=float)
    o = ap.parse_args()
    files = sorted(o.files, key=first_time)
    flows, breaks, stamp_events, near = {}, [], [], []
    for path in files:
        for when, frame, cut in pz.packets(path):
            parsed = pz.udp_payload(frame)
            if parsed is None or cut:
                continue
            src, dst, sport, dport, payload = parsed
            if dst != o.pi or len(payload) < 12 or payload[0] != 2:
                continue
            seconds, samples = struct.unpack(">II", payload[1:9])
            stamp, audio = seconds * o.rate + samples, payload[9:]
            f = flows.setdefault((sport, dport), {"last": None, "frames": None, "chans": None, "prev": None,
                                                  "source": None, "packets": 0})
            if f["frames"] is None:
                if f["last"] is not None:
                    f["frames"] = stamp - f["last"]
                    f["chans"] = len(audio) // 3 // f["frames"]
                    f["prev"], f["source"] = [None] * f["chans"], [None] * f["chans"]
                f["last"] = stamp
                continue
            if stamp != f["last"] + f["frames"]:
                stamp_events.append((when, sport, f["last"], stamp))
            f["last"] = stamp
            f["packets"] += 1
            n, frames = f["chans"], f["frames"]
            if o.at is not None and abs(when - o.at) < 0.005:
                near.append((when, sport, stamp, int.from_bytes(audio[0:3], "big")))
            for i in range(frames):
                for c in range(n):
                    code = int.from_bytes(audio[(i * n + c) * 3:(i * n + c) * 3 + 3], "big")
                    prev, src_ch = f["prev"][c], f["source"][c]
                    f["prev"][c] = code
                    if prev is None:
                        continue
                    if src_ch is not None:
                        if nxt(prev, src_ch) == code:
                            continue
                        breaks.append((when, sport, c + 1, src_ch + 1, stamp, i, classify(code, prev, src_ch)))
                        f["source"][c] = None
                        continue
                    for ch in range(16):
                        if nxt(prev, ch) == code:
                            f["source"][c] = ch
                            break
    print(f"{len(files)} files; flows to the Pi:")
    for (sport, dport), f in sorted(flows.items()):
        print(f"  port {sport}->{dport}: {f['chans']} ch x {f['frames']} frames, {f['packets']} packets, "
              f"sources {','.join(str(s + 1) if s is not None else '-' for s in f['source'] or [])}")
    print(f"stamp irregularities: {len(stamp_events)}")
    for when, sport, last, stamp in stamp_events[:40]:
        print(f"  wall {when:.6f} port {sport}: after {last} came {stamp} ({stamp - last:+d})")
    print(f"sequence breaks: {len(breaks)}")
    for when, sport, ch, src, stamp, i, kind in breaks[:80]:
        print(f"  wall {when:.6f} port {sport} ch {ch} (seq {src}) stamp {stamp} sample {i}: {kind}")
    if near:
        print(f"packets within 5 ms of {o.at}:")
        for when, sport, stamp, code in near:
            print(f"  wall {when:.6f} port {sport} stamp {stamp} ch1 code {code:06x}")


if __name__ == "__main__":
    main()
