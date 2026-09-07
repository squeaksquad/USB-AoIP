#!/usr/bin/env python3
"""Read each RTP stream's stamp phase against the RAVENNA driver's frame grid
from an eth0 capture, and price the free sink-delay range from it.

Why the phase matters: the RAVENNA driver places a sink packet's first sample
at stamp plus sink delay and copies it into the ALSA capture buffer at the TIC
of the 48-sample frame that contains that position (RTP_audio_stream.c
ProcessRTPAudioPacket: ui64RTPSAC += PlayOutDelay; the TIC copies whole
frames at the global SAC, a multiple of 48). So the sink delay costs latency
1:1 but moves the deadline only in whole frames: for a stream whose first
samples sit at phase p of the grid (SAC mod 48), every delay d with
floor((p + d) / 48) equal to floor((p + 144) / 48) = 3 has the deadline of
144, i.e. d in [144 - p, 191 - p] is free against 144 and 144 - p is the
lowest free value (measured 2026-09-07: 132 read 144's lead, 96 had crossed).

How the phase is read: the driver takes the 32-bit RTP timestamp, subtracts
the stream's mediaclk offset (a=mediaclk:direct=N in its SDP) in 32-bit
arithmetic, and widens it with the high 32 bits of the global 64-bit SAC.
2^32 mod 48 is 16, so the wire phase ((ts - offset) mod 2^32) mod 48 is the
grid phase shifted by 16 times the SAC high word, which increments every
2^32 / 48000 s = 24.855 h. The Pi's own source streams (mediaclk offset 0)
are stamped with the driver's SAC, a multiple of 48, so their wire phase is
that shift alone; the grid phase of any other stream is its wire phase minus
the Pi's, mod 48, and needs no epoch, no PTP time, and no root on the Pi
beyond the capture itself.

Input: a tcpdump -w pcap (Ethernet link type), or a raw chunk of one (dd from
an offset; the tool resyncs on the first multicast frame). Streams are keyed
by destination address and UDP port 5004.

Usage: stamp-phase.py CAPTURE [--offset GROUP=N ...] [--reference GROUP]
Defaults: 239.69.16.1 and 239.69.16.2 (the Pi's sources) offset 0 and
reference; 239.69.121.9 and 239.69.193.115 (the Ferrofish's streams, sinks 0
and 1) offset 531217786. Add --offset for anything else.
"""
import argparse
import collections
import datetime
import struct
import sys

DEFAULT_OFFSETS = {
    "239.69.16.1": 0, "239.69.16.2": 0,
    "239.69.121.9": 531217786, "239.69.193.115": 531217786,
}
DEFAULT_REFERENCE = ("239.69.16.1", "239.69.16.2")
FRAME = 48


def plausible(data, off):
    if off + 16 > len(data):
        return None
    sec, frac, caplen, length = struct.unpack("<IIII", data[off:off + 16])
    if caplen != length or not (60 <= caplen <= 1600) or frac >= 1000000000 or not (1.5e9 < sec < 2.0e9):
        return None
    return sec, frac, caplen


def records(path):
    data = open(path, "rb").read()
    pos = 0
    nano = False
    if len(data) >= 24 and struct.unpack("<I", data[:4])[0] in (0xA1B2C3D4, 0xA1B23C4D):
        nano = struct.unpack("<I", data[:4])[0] == 0xA1B23C4D
        if struct.unpack("<I", data[20:24])[0] != 1:
            sys.exit("link type is not Ethernet")
        pos = 24
    else:
        # a chunk: resync on the first multicast destination MAC with a plausible record header before it
        i = 0
        pos = None
        while True:
            j = data.find(b"\x01\x00\x5e", i)
            if j < 16:
                break
            if plausible(data, j - 16):
                pos = j - 16
                break
            i = j + 1
        if pos is None:
            sys.exit("no pcap header and no record to resync on")
        nano = None
    while True:
        h = plausible(data, pos)
        if h is None:
            return
        sec, frac, caplen = h
        frame = data[pos + 16:pos + 16 + caplen]
        if len(frame) < caplen:
            return
        pos += 16 + caplen
        if nano is None:
            nano = frac >= 1000000
        yield sec + frac / (1e9 if nano else 1e6), frame


def rtp(frame):
    if len(frame) < 42 or frame[12:14] != b"\x08\x00" or frame[23] != 17:
        return None
    ihl = (frame[14] & 0x0F) * 4
    udp = 14 + ihl
    if struct.unpack("!H", frame[udp + 2:udp + 4])[0] != 5004:
        return None
    dst = ".".join(str(b) for b in frame[30:34])
    payload = frame[udp + 8:]
    if len(payload) < 12:
        return None
    seq, ts = struct.unpack("!HI", payload[2:8])
    return dst, seq, ts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--offset", action="append", default=[], metavar="GROUP=N", help="mediaclk:direct offset of a destination group")
    ap.add_argument("--reference", action="append", default=[], metavar="GROUP", help="a stream stamped on the driver's grid (the Pi's own source)")
    ap.add_argument("--delay", type=int, default=144, help="the sink delay whose deadline frame the free range is priced against (default 144)")
    args = ap.parse_args()
    offsets = dict(DEFAULT_OFFSETS)
    for item in args.offset:
        group, _, value = item.partition("=")
        offsets[group] = int(value)
    reference = tuple(args.reference) if args.reference else DEFAULT_REFERENCE

    streams = collections.defaultdict(lambda: {"n": 0, "phase": collections.Counter(), "step": collections.Counter(),
                                               "seqgap": 0, "last": None, "t0": None, "t1": None, "jumps": []})
    for ts, frame in records(args.capture):
        hit = rtp(frame)
        if hit is None:
            continue
        dst, seq, stamp = hit
        s = streams[dst]
        s["n"] += 1
        s["t0"] = s["t0"] if s["t0"] is not None else ts
        s["t1"] = ts
        wire = ((stamp - offsets.get(dst, 0)) & 0xFFFFFFFF) % FRAME
        s["phase"][wire] += 1
        if s["last"] is not None:
            lseq, lstamp, lt = s["last"]
            if (lseq + 1) & 0xFFFF != seq:
                s["seqgap"] += 1
            step = (stamp - lstamp) & 0xFFFFFFFF
            s["step"][step] += 1
            if step != FRAME:
                s["jumps"].append((ts, lseq, seq, lstamp, stamp))
        s["last"] = (seq, stamp, ts)
    if not streams:
        sys.exit("no RTP to port 5004 in the capture")

    def utc(t):
        return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    shift = None
    for dst in reference:
        s = streams.get(dst)
        if s and len(s["phase"]) == 1:
            shift = next(iter(s["phase"]))
            print(f"reference {dst}: wire phase {shift} on {s['n']} packets (the SAC high word's 16-per-wrap shift; grid phase 0 by construction)")
            break
    if shift is None:
        print("no reference stream with a single wire phase in the capture: grid phases below are wire phases, unshifted (add --reference or capture the Pi's own source)", file=sys.stderr)
        shift = 0

    for dst, s in sorted(streams.items()):
        wire = s["phase"].most_common(1)[0][0]
        grid = (wire - shift) % FRAME
        role = "reference" if dst in reference else "stream"
        print(f"{dst} ({role}, offset {offsets.get(dst, 0)}): {s['n']} packets {utc(s['t0'])}..{utc(s['t1'])}, "
              f"wire phase {dict(s['phase'])}, seq gaps {s['seqgap']}, stamp steps {dict(s['step']) if len(s['step']) <= 4 else len(s['step'])}")
        for t, lseq, seq, lstamp, stamp in s["jumps"][:5]:
            print(f"    stamp jump at {utc(t)}: seq {lseq}->{seq} stamp {lstamp}->{stamp}")
        if dst not in reference:
            frame_at = (grid + args.delay) // FRAME
            low = frame_at * FRAME - grid
            high = low + FRAME - 1
            print(f"    grid phase {grid}: deadline frame index {frame_at} at delay {args.delay}; the same frame for delays {low}..{high}; "
                  f"lowest free delay {low} ({args.delay - low} samples under {args.delay}); {low - 1} crosses (one frame earlier, the 41-sample holes of 96)")


if __name__ == "__main__":
    main()
