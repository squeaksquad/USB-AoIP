#!/usr/bin/env python3
"""Find the harness impulse in an eth0 packet capture, both directions.

Reads a pcap (tcpdump -w, Ethernet link type, no scapy needed), keeps UDP
packets to the Pi's own source multicast (the impulse leaving, channel 1 of
the first 8-channel L24 stream) and to the Ferrofish's return multicast
(the impulse coming back on the returned channel), and for each packet
whose channel-1 slot holds the impulse sample (0.25 full scale, 0x1FFFFC in
L24 after the Mac's quantisation; other channel slots of that frame zero) prints the capture time,
RTP timestamp, sequence number and frame offset in the packet. Then pairs
each outgoing impulse with the next returning one and prints the wire
loop: outgoing packet handed to the driver -> returning packet received,
which is the wire both ways plus the Ferrofish's in-to-out.

Usage: rtp-impulses.py capture.pcap [--out 239.69.16.1] [--back 239.69.121.9]
       [--port 5004] [--channels 8] [--bridge-log LOG --mono-offset SECONDS]

With --bridge-log and --mono-offset (CLOCK_REALTIME minus CLOCK_MONOTONIC on
the Pi, seconds), the IMPULSE lines are placed on the same clock and each
impulse gets: ravenna-playback write -> packet out (the RAVENNA playback
driver's share), packet out -> packet back (the Ferrofish loop with both
wires), packet back -> ravenna-capture frame (the RAVENNA capture's share:
arrival lead plus the read slot).
"""
import argparse
import re
import statistics
import struct
import sys

# The harness impulse is 0.25 full scale after the Mac's 24-bit quantisation,
# 0x1FFFFC on the wire; anything over 0x100000 (0.125) on the impulse channel
# with the other channel slots of that frame zero is the impulse.
IMPULSE_MINIMUM = 0x100000


def read_pcap(path):
    with open(path, "rb") as fh:
        header = fh.read(24)
        magic = struct.unpack("<I", header[:4])[0]
        if magic == 0xA1B2C3D4:
            endian, nano = "<", False
        elif magic == 0xA1B23C4D:
            endian, nano = "<", True
        elif magic == 0xD4C3B2A1:
            endian, nano = ">", False
        elif magic == 0x4D3CB2A1:
            endian, nano = ">", True
        else:
            sys.exit(f"not a pcap file (magic {magic:#x}); use tcpdump -w, not pcapng")
        link = struct.unpack(endian + "I", header[20:24])[0]
        if link != 1:
            sys.exit(f"link type {link} is not Ethernet")
        while True:
            rec = fh.read(16)
            if len(rec) < 16:
                return
            sec, frac, caplen, _ = struct.unpack(endian + "IIII", rec)
            data = fh.read(caplen)
            ts = sec + frac / (1e9 if nano else 1e6)
            yield ts, data


def udp_payload(data):
    if len(data) < 42 or data[12:14] != b"\x08\x00":
        return None
    ihl = (data[14] & 0x0F) * 4
    if data[23] != 17:
        return None
    dst = ".".join(str(b) for b in data[30:34])
    udp = 14 + ihl
    dport = struct.unpack("!H", data[udp + 2:udp + 4])[0]
    return dst, dport, data[udp + 8:]


def find_impulse(payload, channels):
    if len(payload) < 12:
        return None
    seq, rtp_ts = struct.unpack("!HI", payload[2:8])
    body = payload[12:]
    frame_bytes = channels * 3
    frames = len(body) // frame_bytes
    for frame in range(frames):
        base = frame * frame_bytes
        value = int.from_bytes(body[base:base + 3], "big", signed=True)
        if abs(value) >= IMPULSE_MINIMUM and body[base + 3:base + frame_bytes] == b"\x00" * (frame_bytes - 3):
            return seq, rtp_ts, frame, frames
    return None


def parse_bridge(path):
    events = []
    for raw in open(path, errors="replace"):
        if not raw.startswith("IMPULSE stage="):
            continue
        f = dict(t.partition("=")[::2] for t in raw.split())
        events.append({"stage": f["stage"], "block_ns": int(f["block_ns"]), "offset": int(f["offset"]),
                       "block_frames": int(f["block_frames"]), "position": int(f["position"])})
    return events


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap")
    ap.add_argument("--out", default="239.69.16.1")
    ap.add_argument("--back", default="239.69.121.9")
    ap.add_argument("--port", type=int, default=5004)
    ap.add_argument("--channels", type=int, default=8)
    ap.add_argument("--bridge-log")
    ap.add_argument("--mono-offset", type=float, help="CLOCK_REALTIME - CLOCK_MONOTONIC on the Pi, seconds")
    args = ap.parse_args()

    out, back, counts = [], [], {"out": 0, "back": 0}
    for ts, data in read_pcap(args.pcap):
        parsed = udp_payload(data)
        if not parsed:
            continue
        dst, dport, payload = parsed
        if dport != args.port:
            continue
        if dst == args.out:
            counts["out"] += 1
            hit = find_impulse(payload, args.channels)
            if hit:
                out.append((ts,) + hit)
        elif dst == args.back:
            counts["back"] += 1
            hit = find_impulse(payload, args.channels)
            if hit:
                back.append((ts,) + hit)
    print(f"packets to {args.out}: {counts['out']}, to {args.back}: {counts['back']}; impulses out {len(out)}, back {len(back)}")
    if not out or not back:
        sys.exit(1)

    pairs = []
    j = 0
    for o in out:
        while j < len(back) and back[j][0] < o[0]:
            j += 1
        if j < len(back) and back[j][0] - o[0] < 0.2:
            pairs.append((o, back[j]))
    loops = [(b[0] - o[0]) * 1e3 for o, b in pairs]
    print(f"{len(pairs)} out/back pairs; wire loop (packet out -> packet back) median {statistics.median(loops):.3f} ms "
          f"min {min(loops):.3f} max {max(loops):.3f}")
    # RTP timestamp view: the Ferrofish's stamp minus the Pi's stamp for the same impulse, in samples
    stamps = [((b[2] - o[2]) & 0xFFFFFFFF) for o, b in pairs]
    print(f"Ferrofish stamp - Pi stamp for the same impulse: median {statistics.median(stamps):.0f} samples "
          f"min {min(stamps)} max {max(stamps)} (frame offsets out {statistics.median(o[3] for o, _ in pairs):.0f} "
          f"back {statistics.median(b[3] for _, b in pairs):.0f})")
    print("first pairs (utc s, seq, rtp_ts, frame): out / back")
    for o, b in pairs[:3]:
        print(f"  {o[0]:.6f} {o[1]} {o[2]} {o[3]}  /  {b[0]:.6f} {b[1]} {b[2]} {b[3]}   loop {(b[0]-o[0])*1e3:.3f} ms")

    if args.bridge_log and args.mono_offset is not None:
        events = parse_bridge(args.bridge_log)
        frame_ns = 1e9 / 48000
        writes = [e["block_ns"] / 1e9 + args.mono_offset for e in events if e["stage"] == "ravenna-playback"]
        reads = [(e["block_ns"] - (e["block_frames"] - 1 - e["offset"]) * frame_ns) / 1e9 + args.mono_offset
                 for e in events if e["stage"] == "ravenna-capture"]
        w2o, b2r = [], []
        for o, b in pairs:
            w = max((t for t in writes if t <= o[0] + 0.001), default=None)
            r = min((t for t in reads if t >= b[0] - 0.001), default=None)
            if w is not None and o[0] - w < 0.05:
                w2o.append((o[0] - w) * 1e3)
            if r is not None and r - b[0] < 0.05:
                b2r.append((r - b[0]) * 1e3)
        if w2o:
            print(f"ravenna-playback write -> packet out: median {statistics.median(w2o):.3f} ms min {min(w2o):.3f} max {max(w2o):.3f} n {len(w2o)}")
        if b2r:
            print(f"packet back -> ravenna-capture frame: median {statistics.median(b2r):.3f} ms min {min(b2r):.3f} max {max(b2r):.3f} n {len(b2r)}")


if __name__ == "__main__":
    main()
