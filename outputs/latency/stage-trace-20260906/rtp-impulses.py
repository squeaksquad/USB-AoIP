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
       [--loop [--loop-minimum 0x2000]]
With --loop (the AoIP loop mode, AOIP_LOOP_DESIGN.md, 2026-09-12) the
outgoing stream carries two kinds of impulse: the bridge's own injected one at
0.25 full scale and, one loop later, its re-emission 40 dB down through the
loop-measure preset. The re-emission is the loop's output: each returning
impulse is paired with the next re-emission and the pairing gives the AoIP
in -> AoIP out figure at the Pi's port, in wall time from the capture and in
samples from the RTP stamps (Pi stamp of the re-emission minus the Ferrofish
stamp of the return, both on the PTP media clock). With --bridge-log the
IMPULSE lines add the bridge's own dwell, ravenna-capture frame ->
ravenna-playback write of the re-emission (classified by value).

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
# The loop's re-emission: 0.25 full scale at -40 dB is 0.0025, 0x5200 in L24;
# anything from 0x2000 (about -54 dBFS) up to the injected level is one, and
# the second pass (-80 dB, 0x52) is below it, as is any rounding.
LOOP_MINIMUM_DEFAULT = 0x2000


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


def find_impulse(payload, channels, minimum=IMPULSE_MINIMUM):
    """(seq, rtp_ts, frame, frames, value) of the first channel-1 sample at or
    over `minimum` whose other channel slots are zero, else None."""
    if len(payload) < 12:
        return None
    seq, rtp_ts = struct.unpack("!HI", payload[2:8])
    body = payload[12:]
    frame_bytes = channels * 3
    frames = len(body) // frame_bytes
    for frame in range(frames):
        base = frame * frame_bytes
        value = int.from_bytes(body[base:base + 3], "big", signed=True)
        if abs(value) >= minimum and body[base + 3:base + frame_bytes] == b"\x00" * (frame_bytes - 3):
            return seq, rtp_ts, frame, frames, abs(value)
    return None


def parse_bridge(path):
    events = []
    for raw in open(path, errors="replace"):
        if not raw.startswith("IMPULSE stage="):
            continue
        f = dict(t.partition("=")[::2] for t in raw.split())
        events.append({"stage": f["stage"], "block_ns": int(f["block_ns"]), "offset": int(f["offset"]),
                       "block_frames": int(f["block_frames"]), "position": int(f["position"]),
                       "value": float(f.get("value", "0"))})
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
    ap.add_argument("--loop", action="store_true",
                    help="AoIP loop mode: pair each returning impulse with its -40 dB re-emission on the outgoing stream")
    ap.add_argument("--loop-minimum", type=lambda v: int(v, 0), default=LOOP_MINIMUM_DEFAULT,
                    help="smallest L24 magnitude read as a re-emission (default 0x2000)")
    args = ap.parse_args()
    out_minimum = args.loop_minimum if args.loop else IMPULSE_MINIMUM

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
            hit = find_impulse(payload, args.channels, out_minimum)
            if hit:
                out.append((ts,) + hit)
        elif dst == args.back:
            counts["back"] += 1
            hit = find_impulse(payload, args.channels)
            if hit:
                back.append((ts,) + hit)
    reemitted = []
    if args.loop:
        # Split the outgoing hits by magnitude: the injected impulses stay in
        # `out` for the wire-loop pairing below; the re-emissions are the
        # loop's output.
        injected = [o for o in out if o[5] >= IMPULSE_MINIMUM]
        reemitted = [o for o in out if o[5] < IMPULSE_MINIMUM]
        out = injected
        print(f"loop mode: injected {len(injected)}, re-emitted {len(reemitted)} (out threshold {out_minimum:#x})")
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

    loop_pairs = []
    if args.loop:
        k = 0
        for b in back:
            while k < len(reemitted) and reemitted[k][0] <= b[0]:
                k += 1
            if k < len(reemitted) and reemitted[k][0] - b[0] < 0.2:
                loop_pairs.append((b, reemitted[k]))
        if loop_pairs:
            wall = [(r[0] - b[0]) * 1e3 for b, r in loop_pairs]
            # Stamp plus frame offset on each side: the Pi's playout stamp of
            # the re-emitted sample minus the Ferrofish's stamp of the
            # returned one, both on the PTP media clock.
            samples = [(((r[2] + r[3]) - (b[2] + b[3]) + 2**31) & 0xFFFFFFFF) - 2**31 for b, r in loop_pairs]
            print(f"{len(loop_pairs)} back/re-emit pairs; AoIP in -> AoIP out at the Pi's port (packet back -> re-emitted packet out): "
                  f"median {statistics.median(wall):.3f} ms min {min(wall):.3f} max {max(wall):.3f}")
            print(f"  on the media clock (Pi stamp of the re-emission - Ferrofish stamp of the return): "
                  f"median {statistics.median(samples):.0f} samples min {min(samples)} max {max(samples)} "
                  f"({statistics.median(samples) / 48.0:.3f} ms); re-emission level median {int(statistics.median(r[5] for _, r in loop_pairs)):#x}")
            print("first loop pairs (utc s, seq, rtp_ts, frame): back / re-emit")
            for b, r in loop_pairs[:3]:
                print(f"  {b[0]:.6f} {b[1]} {b[2]} {b[3]}  /  {r[0]:.6f} {r[1]} {r[2]} {r[3]}   loop {(r[0]-b[0])*1e3:.3f} ms")
        else:
            print("no back/re-emit pairs: no re-emission within 0.2 s of a returning impulse")

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
        if args.loop:
            # The bridge's own dwell on the loop: the returned impulse's
            # capture frame time to the re-emission's playback write, the
            # write classified by value (the injected one is 0.25, the
            # re-emission about 0.0025).
            full_reads = [(e["block_ns"] - (e["block_frames"] - 1 - e["offset"]) * frame_ns) / 1e9 + args.mono_offset
                          for e in events if e["stage"] == "ravenna-capture" and e["value"] >= 0.1]
            small_writes = [e["block_ns"] / 1e9 + args.mono_offset
                            for e in events if e["stage"] == "ravenna-playback" and e["value"] < 0.1]
            dwell = []
            for r in full_reads:
                w = min((t for t in small_writes if t >= r), default=None)
                if w is not None and w - r < 0.05:
                    dwell.append((w - r) * 1e3)
            if dwell:
                print(f"ravenna-capture frame -> ravenna-playback write of the re-emission (bridge dwell): "
                      f"median {statistics.median(dwell):.3f} ms min {min(dwell):.3f} max {max(dwell):.3f} n {len(dwell)}")
            else:
                print("no bridge dwell pairs: the trace needs --impulse-threshold below 0.0025 and a holdoff shorter than the loop")


if __name__ == "__main__":
    main()
