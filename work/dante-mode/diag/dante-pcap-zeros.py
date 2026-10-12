#!/usr/bin/env python3
"""Where are the zeros? Reads an eth0 capture of Dante audio flows and reports,
per flow and direction, the runs of zero bytes inside the audio payload.

Written 2026-10-12 for the four-sample holes drawn at some endpoint starts
(RESULTS.md, "The four-sample holes are drawn at 2 ms as well"). With noise on
every channel a real sample is never three zero bytes, so a run of zero bytes
that covers whole frames is audio that was not there when the packet was made.
If the runs are in the packets the Pi sends, the loss is before the wire
(owner or Inferno transmit); if only in the packets the Pi receives, it is the
far device or what feeds it; if in neither, it is after receipt on the Pi.

Packet layout, from Inferno's flows_tx.rs / flows_rx.rs: one byte 0x02, the
timestamp as seconds and samples-within-the-second (two big-endian u32), then
interleaved big-endian samples, `channels * bytes_per_sample` a frame.

  dante-pcap-zeros.py CAPTURE.pcap [--pi 169.254.92.97] [--min-run 9] [--bytes 3]

Capture on the Pi (root), bounded, to tmpfs:
  timeout 4 tcpdump -i eth0 -n -s 0 -B 32768 -w /dev/shm/x.pcap \
      'udp and host <far device> and greater 400'
Pure standard library; classic pcap only (tcpdump -w), Ethernet link type.
"""
import argparse
import collections
import struct
import sys


def packets(path):
    with open(path, "rb") as f:
        head = f.read(24)
        if len(head) < 24:
            sys.exit("not a pcap file")
        magic = struct.unpack("<I", head[:4])[0]
        if magic in (0xA1B2C3D4, 0xA1B23C4D):
            order, nano = "<", magic == 0xA1B23C4D
        elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
            order, nano = ">", magic == 0x4D3CB2A1
        else:
            sys.exit("not a classic pcap file (pcapng is not read)")
        linktype = struct.unpack(order + "I", head[20:24])[0]
        if linktype != 1:
            sys.exit(f"link type {linktype}, expected Ethernet (1)")
        while True:
            record = f.read(16)
            if len(record) < 16:
                return
            seconds, fraction, captured, original = struct.unpack(order + "IIII", record)
            data = f.read(captured)
            if len(data) < captured:
                return
            yield seconds + fraction / (1e9 if nano else 1e6), data, captured < original


def udp_payload(frame):
    """(src, dst, sport, dport, payload) of an untagged or VLAN-tagged IPv4 UDP frame, else None."""
    offset = 12
    ethertype = struct.unpack(">H", frame[offset:offset + 2])[0]
    if ethertype == 0x8100:
        offset += 4
        ethertype = struct.unpack(">H", frame[offset:offset + 2])[0]
    if ethertype != 0x0800:
        return None
    ip = offset + 2
    if len(frame) < ip + 20 or frame[ip] >> 4 != 4 or frame[ip + 9] != 17:
        return None
    if struct.unpack(">H", frame[ip + 6:ip + 8])[0] & 0x3FFF:
        return None  # fragment
    header = (frame[ip] & 0x0F) * 4
    udp = ip + header
    if len(frame) < udp + 8:
        return None
    sport, dport, length = struct.unpack(">HHH", frame[udp:udp + 6])
    src = ".".join(str(b) for b in frame[ip + 12:ip + 16])
    dst = ".".join(str(b) for b in frame[ip + 16:ip + 20])
    return src, dst, sport, dport, frame[udp + 8:udp + length]


def zero_runs(audio, minimum):
    """(start, length) of every run of zero bytes at least `minimum` long."""
    runs = []
    position = 0
    size = len(audio)
    while True:
        start = audio.find(b"\x00" * minimum, position)
        if start < 0:
            return runs
        end = start + minimum
        while end < size and audio[end] == 0:
            end += 1
        runs.append((start, end - start))
        position = end


class Flow:
    def __init__(self):
        self.count = 0
        self.sizes = collections.Counter()
        self.with_runs = 0
        self.all_zero = 0
        self.runs = collections.Counter()
        self.steps = collections.Counter()
        self.last_stamp = None
        self.gaps = []
        self.last_time = None
        self.first_time = None
        self.run_packet_index = []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture")
    parser.add_argument("--pi", default="169.254.92.97", help="the Pi's eth0 address, to name the directions")
    parser.add_argument("--min-run", type=int, default=9, help="shortest run of zero bytes reported (9 = three 24-bit samples)")
    parser.add_argument("--bytes", type=int, default=3, help="bytes per sample, for the frame arithmetic in the report")
    parser.add_argument("--rate", type=int, default=48000)
    options = parser.parse_args()

    flows = collections.defaultdict(Flow)
    truncated = other = 0
    for when, frame, cut in packets(options.capture):
        parsed = udp_payload(frame)
        if parsed is None:
            other += 1
            continue
        src, dst, sport, dport, payload = parsed
        if len(payload) < 9 + options.bytes or payload[0] != 2:
            other += 1
            continue
        if cut:
            truncated += 1
            continue
        flow = flows[(src, sport, dst, dport)]
        audio = payload[9:]
        seconds, samples = struct.unpack(">II", payload[1:9])
        stamp = seconds * options.rate + samples
        if flow.last_stamp is not None:
            flow.steps[stamp - flow.last_stamp] += 1
            flow.gaps.append(when - flow.last_time)
        else:
            flow.first_time = when
        flow.last_stamp, flow.last_time = stamp, when
        flow.sizes[len(audio)] += 1
        runs = zero_runs(audio, options.min_run)
        if runs:
            if len(runs) == 1 and runs[0][1] == len(audio):
                flow.all_zero += 1
            else:
                flow.with_runs += 1
                flow.run_packet_index.append(flow.count)
                for run in runs:
                    flow.runs[run] += 1
        flow.count += 1

    if not flows:
        sys.exit(f"no Dante audio packets found ({other} other packets)")
    print(f"{options.capture}: {sum(f.count for f in flows.values())} audio packets in {len(flows)} flows, "
          f"{other} other packets, {truncated} truncated and skipped")
    for key in sorted(flows, key=lambda k: (k[0] != options.pi, k)):
        src, sport, dst, dport = key
        flow = flows[key]
        direction = "Pi sends " if src == options.pi else "Pi receives" if dst == options.pi else "other      "
        size = flow.sizes.most_common(1)[0][0]
        step = flow.steps.most_common(1)[0][0] if flow.steps else 0
        channels = size // (step * options.bytes) if step else 0
        seconds = (flow.last_time - flow.first_time) if flow.count > 1 else 0.0
        print(f"\n{direction}  {src}:{sport} -> {dst}:{dport}")
        print(f"  packets {flow.count} over {seconds:.3f} s, audio bytes {dict(flow.sizes)}, "
              f"timestamp steps {dict(flow.steps.most_common(4))}"
              + (f", so {step} frames a packet, {channels} channels" if step else ""))
        if flow.gaps:
            gaps = sorted(flow.gaps)
            print(f"  arrival gap us: median {gaps[len(gaps) // 2] * 1e6:.0f}, "
                  f"99.9% {gaps[min(len(gaps) - 1, int(len(gaps) * 0.999))] * 1e6:.0f}, max {gaps[-1] * 1e6:.0f}")
        print(f"  packets with a zero run of {options.min_run}+ bytes: {flow.with_runs} "
              f"({100.0 * flow.with_runs / flow.count:.1f} %); wholly zero packets: {flow.all_zero}")
        stride = channels * options.bytes if channels else 0
        for (start, length), n in flow.runs.most_common(6):
            where = ""
            if stride:
                where = (f"  = frames {start / stride:.2f} to {(start + length) / stride:.2f} of {step} "
                         f"({length / stride:.2f} frames)")
            print(f"    run at byte {start}, {length} bytes: {n} packets{where}")
        if len(flow.run_packet_index) > 1:
            spacing = collections.Counter(b - a for a, b in zip(flow.run_packet_index, flow.run_packet_index[1:]))
            print(f"    spacing between affected packets (in packets): {dict(spacing.most_common(5))}")


if __name__ == "__main__":
    main()
