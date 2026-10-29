#!/usr/bin/env python3
"""sequence-slips.py CAPTURE.pcap [--pi 169.254.92.97] [--limit 8388590]: where the
bitexact sequence breaks on the wire (2026-10-29, the 96 kHz slips on the 8-channel loop).

`usb16x16-latency bitexact` sends each output channel its own 24-bit LCG
(BitExact.swift, BitExactSequence: code' = code * 1664525 + (1013904223 + 2 * ch)
mod 2^24, clamped at the host-gain limit). At unity gain the codes cross the Pi
unchanged, so every Dante channel in a capture can be checked on its own: which
output's sequence it carries, and every sample where the next code is not the
one the sequence predicts. A frame dropped or repeated anywhere before the wire
shows as a break in the flows the Pi sends; one in the far loop shows only in
the flows the Pi receives; one in neither is after receipt on the Pi.

Also reported per flow: packets whose Dante timestamp does not follow the last
one (a lost or reordered packet, not a slip in the audio).
Standard library only; reuses dante-pcap-zeros.py's pcap reader and frame parser.
"""
import argparse
import collections
import importlib.util
import struct
from pathlib import Path

repo = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("pz", repo / "work/dante-mode/diag/dante-pcap-zeros.py")
pz = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pz)

MASK = 0xFFFFFF


def predict(code, ch):
    return (code * 1664525 + ((1013904223 + 2 * ch) & MASK)) & MASK


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--pi", default="169.254.92.97")
    ap.add_argument("--rate", type=int, default=96000)
    ap.add_argument("--limit", type=int, default=8388590, help="codes this large may be clamped: not judged")
    o = ap.parse_args()

    flows = {}
    breaks = []
    gaps = []
    t0 = None
    for when, frame, cut in pz.packets(o.capture):
        parsed = pz.udp_payload(frame)
        if parsed is None or cut:
            continue
        src, dst, sport, dport, payload = parsed
        if len(payload) < 12 or payload[0] != 2:
            continue
        t0 = when if t0 is None else t0
        key = (src, sport, dst, dport)
        seconds, samples = struct.unpack(">II", payload[1:9])
        audio = payload[9:]
        f = flows.get(key)
        if f is None:
            f = flows[key] = {"last": None, "chans": None, "frames": None, "prev": None,
                              "source": None, "matches": None, "breaks": None, "packets": 0}
        stamp = seconds * o.rate + samples
        if f["chans"] is None:
            if f["last"] is None:
                f["last"] = stamp
                continue
            f["frames"] = stamp - f["last"]
            f["chans"] = len(audio) // 3 // f["frames"]
            n = f["chans"]
            f["prev"], f["source"] = [None] * n, [None] * n
            f["matches"], f["breaks"] = [0] * n, [0] * n
        elif stamp != f["last"] + f["frames"]:
            gaps.append((when - t0, key, f["last"], stamp))
            f["prev"] = [None] * f["chans"]   # do not judge across a missing packet
        f["last"] = stamp
        f["packets"] += 1
        n, frames = f["chans"], f["frames"]
        for i in range(frames):
            for c in range(n):
                off = (i * n + c) * 3
                code = int.from_bytes(audio[off:off + 3], "big")
                signed = code - 0x1000000 if code & 0x800000 else code
                prev = f["prev"][c]
                f["prev"][c] = None if abs(signed) >= o.limit else code
                if prev is None:
                    continue
                src_ch = f["source"][c]
                if src_ch is not None:
                    if predict(prev, src_ch) == code:
                        f["matches"][c] += 1
                        continue
                    f["breaks"][c] += 1
                    # what happened: a repeat (code == prev), or a skip (code is two ahead)?
                    kind = "repeat" if code == prev else (
                        "skip1" if predict(predict(prev, src_ch), src_ch) == code else "other")
                    breaks.append((when - t0, key, c, stamp + i, src_ch + 1, kind))
                    f["source"][c] = None
                    continue
                for ch in range(16):
                    if predict(prev, ch) == code:
                        f["source"][c] = ch
                        f["matches"][c] += 1
                        break

    print(f"capture {o.capture}: {len(flows)} flows")
    for key, f in sorted(flows.items()):
        way = "Pi sends" if key[0] == o.pi else "Pi receives"
        sources = ",".join(str(s + 1) if s is not None else "-" for s in (f["source"] or []))
        print(f"  {way:11} {key[0]}:{key[1]} -> {key[2]}:{key[3]}  {f['chans']} ch x {f['frames']} frames, "
              f"{f['packets']} packets; sources {sources}; matches {f['matches']}; breaks {f['breaks']}")
    print(f"timestamp gaps: {len(gaps)}")
    for t, key, last, stamp in gaps[:40]:
        print(f"  t+{t:9.3f}s {key[0]}:{key[1]}->{key[2]}:{key[3]} after {last} came {stamp} ({stamp - last})")
    # group breaks that share a capture moment (within 10 ms) into events
    print(f"sequence breaks: {len(breaks)}")
    events = []
    for b in breaks:
        if events and b[0] - events[-1][-1][0] < 0.01:
            events[-1].append(b)
        else:
            events.append([b])
    for ev in events:
        t = ev[0][0]
        detail = collections.Counter(("sends" if b[1][0] == o.pi else "receives", b[1][1], b[5]) for b in ev)
        stamps = sorted({b[3] for b in ev})
        print(f"  t+{t:9.3f}s  {len(ev)} channel breaks; Dante stamp {stamps[0]}..{stamps[-1]}; "
              + "; ".join(f"{w} port {p} {k} x{n}" for (w, p, k), n in sorted(detail.items())))


if __name__ == "__main__":
    main()
