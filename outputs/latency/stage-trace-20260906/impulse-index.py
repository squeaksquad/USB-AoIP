#!/usr/bin/env python3
"""Place a session's round trip in the index domain, one row per prime epoch.

Reads a full-rate bridge log carrying IMPULSE lines (bridge --impulse-trace 1)
and, optionally, the eth0 capture taken during it. Every term is a difference
of stream indices for the same impulse, exact per impulse; no queue estimate
enters (impulse-stages.py's queue terms are 1 Hz depth samples and carry up to
a period of error, which is why its sums close only to within a period).

From the bridge log alone (positions are per-PCM indices, restarting at 0 at
each prime, so all four are read on the same epoch):

  pos_tx     ravenna-playback position - usb-capture position      (TX ring dwell)
  pos_aes67  ravenna-capture position  - ravenna-playback position (the AES67 segment
             as the bridge's own two PCM indices see it)
  pos_rx     usb-playback position     - ravenna-capture position  (RX ring dwell)
  pos_pi     usb-playback position     - usb-capture position      (the sum)
  usb        --level minus pos_pi: the two USB legs together plus the relative
             start of the two gadget PCMs on the Mac's timeline

With --pcap and --mono-offset (CLOCK_REALTIME - CLOCK_MONOTONIC on the Pi,
seconds; constant per boot) the AES67 segment splits three ways in the RTP
stamp domain. The Pi's send times for every outgoing packet fix the relation
between its RTP stamp (SAC) and the Pi's realtime clock by a straight-line fit,
so an instant on the bridge's clock maps to a stamp:

  tx_lead    packet-out stamp of the impulse - SAC at the bridge's write instant
             (frames the write sits ahead of its transmission: the ALSA queue at
             the write plus the driver's slot convention)
  loop       Ferrofish stamp - Pi stamp for the same impulse, minus the
             Ferrofish's mediaclk offset (--ferrofish-offset, from its SDP):
             the Ferrofish's own in-to-out in its stamp domain
  rx_lag     SAC at the bridge's read instant - Ferrofish stamp
             (frames the read sits behind the stamp: sink delay as placed, plus
             the arrival lead and the read slot)

  tx_lead + loop + rx_lag = write_to_read x 48 kHz (printed as the check).

Also per epoch: start_tx = stamp of playback position 0 (the SAC the TX PCM's
first frame was stamped with) and start_rx = SAC at which capture position 0
was read; both are absolute stamps, and their difference start_tx - start_rx
is the relative start of the two RAVENNA PCMs in the driver's index domain,
the only session-set quantity inside pos_aes67 besides loop and the placement.

Epochs: a new epoch begins at each PRIMED line that follows at least one
IMPULSE line since the previous boundary (a prime pair is one boundary; an
RX-only re-prime is its own boundary because two of the four positions
restart). --level takes one value for all epochs or one per epoch, comma
separated, in epoch order; an epoch with fewer than --min impulses is listed
but not summarised.
"""
import argparse
import re
import statistics
import struct
import sys
from datetime import datetime, timezone

STAGES = ["usb-capture", "ravenna-playback", "ravenna-capture", "usb-playback"]
FRAME_NS = 1e9 / 48000.0
IMPULSE_MINIMUM = 0x100000
WRAP = 1 << 32


def signed32(value):
    value &= WRAP - 1
    return value - WRAP if value >= WRAP // 2 else value


def utc(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def parse_log(path):
    """Return (impulse groups with epoch index, primed lines per epoch)."""
    events, primes, epoch, seen_since_prime = [], {0: []}, 0, False
    for raw in open(path, errors="replace"):
        line = raw.strip()
        if line.startswith("PRIMED "):
            if seen_since_prime:
                epoch += 1
                primes[epoch] = []
                seen_since_prime = False
            primes[epoch].append(line)
            continue
        if not line.startswith("IMPULSE "):
            continue
        fields = dict(token.partition("=")[::2] for token in line.split()[1:])
        try:
            events.append({
                "epoch": epoch,
                "stage": fields["stage"],
                "position": int(fields["position"]),
                "block_frames": int(fields["block_frames"]),
                "offset": int(fields["offset"]),
                "depth": int(fields["depth"]),
                "block_ns": int(fields["block_ns"]),
                "now_ns": int(fields["now_ns"]),
                "t_us": int(fields["t_us"]),
            })
            seen_since_prime = True
        except (KeyError, ValueError):
            continue
    groups, current = [], None
    for event in events:
        if event["stage"] == STAGES[0]:
            if current and len(current) == 4:
                groups.append(current)
            current = {event["stage"]: event}
            continue
        if current is None or len(current) == 4:
            continue
        expected = STAGES[len(current)]
        if (event["stage"] == expected and event["epoch"] == current[STAGES[0]]["epoch"]
                and event["now_ns"] - current[STAGES[0]]["now_ns"] < 200_000_000):
            current[event["stage"]] = event
        else:
            current = None
    if current and len(current) == 4:
        groups.append(current)
    return groups, primes


def capture_frame_ns(event):
    """Monotonic ns of the impulse frame for a capture stage."""
    return event["block_ns"] - (event["block_frames"] - 1 - event["offset"]) * FRAME_NS


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
        if struct.unpack(endian + "I", header[20:24])[0] != 1:
            sys.exit("link type is not Ethernet")
        while True:
            rec = fh.read(16)
            if len(rec) < 16:
                return
            sec, frac, caplen, _ = struct.unpack(endian + "IIII", rec)
            data = fh.read(caplen)
            yield sec + frac / (1e9 if nano else 1e6), data


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


def rtp_fields(payload, channels):
    if len(payload) < 12:
        return None
    seq, rtp_ts = struct.unpack("!HI", payload[2:8])
    body = payload[12:]
    frame_bytes = channels * 3
    frames = len(body) // frame_bytes
    impulse = None
    for frame in range(frames):
        base = frame * frame_bytes
        value = int.from_bytes(body[base:base + 3], "big", signed=True)
        if abs(value) >= IMPULSE_MINIMUM and body[base + 3:base + frame_bytes] == b"\x00" * (frame_bytes - 3):
            impulse = frame
            break
    return seq, rtp_ts, frames, impulse


def load_capture(path, out, back, port, channels):
    """Return (out packets [(ts, stamp of frame 0)], out impulses, back impulses)."""
    out_pkts, out_imp, back_imp = [], [], []
    for ts, data in read_pcap(path):
        parsed = udp_payload(data)
        if not parsed:
            continue
        dst, dport, payload = parsed
        if dport != port:
            continue
        fields = rtp_fields(payload, channels)
        if not fields:
            continue
        seq, rtp_ts, frames, impulse = fields
        if dst == out:
            out_pkts.append((ts, rtp_ts))
            if impulse is not None:
                out_imp.append((ts, (rtp_ts + impulse) & (WRAP - 1), seq, impulse))
        elif dst == back and impulse is not None:
            back_imp.append((ts, (rtp_ts + impulse) & (WRAP - 1), seq, impulse))
    return out_pkts, out_imp, back_imp


def fit_stamp_clock(out_pkts):
    """Least squares ts = a + b * stamp over the Pi's outgoing packets (unwrapped)."""
    base = out_pkts[0][1]
    xs, ys = [], []
    last = base
    unwrapped = 0
    for ts, stamp in out_pkts:
        step = signed32(stamp - last)
        unwrapped += step
        last = stamp
        xs.append(unwrapped)
        ys.append(ts)
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    b = sxy / sxx
    a = my - b * mx
    residuals = [y - (a + b * x) for x, y in zip(xs, ys)]
    return base, a, b, max(abs(r) for r in residuals) * 1e3, statistics.median(abs(r) for r in residuals) * 1e3


def stamp_at(clock, ts):
    """Pi stamp (float, unwrapped from the fit base) at realtime ts."""
    base, a, b, _, _ = clock
    return (ts - a) / b


def stamp_unwrap(clock, stamp):
    base = clock[0]
    return signed32(stamp - base)


def nearest(seq, key, lo, hi):
    """Element of seq (sorted by key) with lo <= key <= hi nearest the midpoint, or None."""
    best, best_d = None, None
    mid = (lo + hi) / 2
    for item in seq:
        k = key(item)
        if k < lo:
            continue
        if k > hi:
            break
        d = abs(k - mid)
        if best is None or d < best_d:
            best, best_d = item, d
    return best


def summarise(name, values, fmt="{:9.1f}"):
    if not values:
        return f"  {name:<10} no data"
    values = sorted(values)
    return (f"  {name:<10} median " + fmt.format(statistics.median(values)) + "  min " + fmt.format(values[0])
            + "  max " + fmt.format(values[-1]) + f"  n {len(values)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--level", help="harness samples at 64 frames: one value, or one per epoch, comma separated")
    ap.add_argument("--pcap")
    ap.add_argument("--mono-offset", type=float, help="CLOCK_REALTIME - CLOCK_MONOTONIC on the Pi, seconds")
    ap.add_argument("--out", default="239.69.16.1")
    ap.add_argument("--back", default="239.69.121.9")
    ap.add_argument("--port", type=int, default=5004)
    ap.add_argument("--channels", type=int, default=8)
    ap.add_argument("--ferrofish-offset", type=int, default=531217786,
                    help="a=mediaclk:direct of the Ferrofish's return stream (its SDP); the Pi's is 0")
    ap.add_argument("--min", type=int, default=5, help="impulses an epoch needs to be summarised")
    ap.add_argument("--csv", help="write per-impulse rows here")
    args = ap.parse_args()

    groups, primes = parse_log(args.log)
    print(f"{args.log}: {len(groups)} complete impulses in {len(primes)} epochs")
    levels = {}
    if args.level:
        values = [int(v) for v in args.level.split(",")]
        for i in range(len(primes)):
            levels[i] = values[i] if len(values) > 1 and i < len(values) else values[0]

    clock = None
    out_imp = back_imp = []
    if args.pcap:
        if args.mono_offset is None:
            sys.exit("--pcap needs --mono-offset")
        out_pkts, out_imp, back_imp = load_capture(args.pcap, args.out, args.back, args.port, args.channels)
        print(f"capture: {len(out_pkts)} packets out, impulses out {len(out_imp)} back {len(back_imp)}, "
              f"{utc(out_pkts[0][0])} - {utc(out_pkts[-1][0])} UTC")
        clock = fit_stamp_clock(out_pkts)
        print(f"stamp clock fit over the Pi's packets: {clock[2] * 48000:.9f} s per 48000 stamps "
              f"({(clock[2] * 48000 - 1) * 1e6:+.1f} ppm against the Pi's realtime), "
              f"send-time residual median {clock[4]:.3f} ms max {clock[3]:.3f} ms")

    rows = []
    for g in groups:
        cap = g["usb-capture"]
        rav_play = g["ravenna-playback"]
        rav_cap = g["ravenna-capture"]
        usb_play = g["usb-playback"]
        row = {
            "epoch": cap["epoch"],
            "t_us": cap["t_us"],
            "pos_tx": rav_play["position"] - cap["position"],
            "pos_aes67": rav_cap["position"] - rav_play["position"],
            "pos_rx": usb_play["position"] - rav_cap["position"],
            "pos_pi": usb_play["position"] - cap["position"],
            "write_to_read": (capture_frame_ns(rav_cap) - rav_play["block_ns"]) * 48000e-9,
            "cap_to_write": (usb_play["block_ns"] - capture_frame_ns(cap)) * 48000e-9,
            "tx_depth": rav_play["depth"],
            "rx_depth": usb_play["depth"],
            # usb-capture frame instant -> usb-playback play instant (write + depth at the write + offset)
            "pi_total": (usb_play["block_ns"] + (usb_play["depth"] + usb_play["offset"]) * FRAME_NS
                         - capture_frame_ns(cap)) * 48000e-9,
        }
        if clock is not None:
            write_ts = rav_play["block_ns"] / 1e9 + args.mono_offset
            read_ts = capture_frame_ns(rav_cap) / 1e9 + args.mono_offset
            o = nearest(out_imp, lambda p: p[0], write_ts - 0.002, write_ts + 0.030)
            b = nearest(back_imp, lambda p: p[0], read_ts - 0.030, read_ts + 0.002)
            row["utc"] = utc(write_ts)
            if o and b:
                s_out = stamp_unwrap(clock, o[1])
                s_back_rel = signed32(b[1] - args.ferrofish_offset - o[1])
                sac_write = stamp_at(clock, write_ts)
                sac_read = stamp_at(clock, read_ts)
                row["tx_lead"] = s_out - sac_write
                row["loop"] = s_back_rel
                row["rx_lag"] = sac_read - (s_out + s_back_rel)
                row["stamp_sum"] = row["tx_lead"] + row["loop"] + row["rx_lag"]
                # absolute stamps: the playback PCM's frame 0 as stamped; the SAC at which
                # the capture PCM's frame 0 was read
                row["start_tx"] = (o[1] - rav_play["position"]) & (WRAP - 1)
                row["start_rx"] = (clock[0] + int(round(sac_read)) - rav_cap["position"]) & (WRAP - 1)
                row["start_gap"] = signed32(row["start_tx"] - row["start_rx"])
                row["pkt_out_ms"] = (o[0] - write_ts) * 1e3
                row["pkt_back_ms"] = (read_ts - b[0]) * 1e3
                row["out_frame"] = o[3]
                row["back_frame"] = b[3]
        rows.append(row)

    epochs = sorted(set(r["epoch"] for r in rows) | set(primes))
    for e in epochs:
        er = [r for r in rows if r["epoch"] == e]
        print()
        print(f"epoch {e}: {len(er)} impulses" + (f", level {levels[e]}" if e in levels else "")
              + (f", {er[0]['utc']} - {er[-1]['utc']} UTC" if er and 'utc' in er[0] else
                 (f", bridge t_us {er[0]['t_us']} - {er[-1]['t_us']}" if er else "")))
        for line in primes.get(e, []):
            keep = re.findall(r"(direction=\S+|grid_phase_us=\S+|ring_at_prime=\S+|overshoot=\S+|align_dropped=\S+"
                              r"|prime_phase_us=\S+|first_tick_wait_us=\S+|front_age_frames=\S+)", line)
            print("  PRIMED " + " ".join(keep))
        if len(er) < args.min:
            continue
        print("  index chain (frames, exact per impulse):")
        for key in ["pos_tx", "pos_aes67", "pos_rx", "pos_pi"]:
            print(summarise(key, [r[key] for r in er], "{:9.0f}"))
        if e in levels:
            pos_pi = statistics.median(r["pos_pi"] for r in er)
            print(f"  usb        level {levels[e]} - pos_pi {pos_pi:.0f} = {levels[e] - pos_pi:.0f} "
                  f"(two USB legs plus the gadget PCMs' relative start)")
        print("  time domain (samples; write_to_read and cap_to_write are exact ends, pi_total adds the depth at the write):")
        for key in ["write_to_read", "cap_to_write", "pi_total", "rx_depth", "tx_depth"]:
            print(summarise(key, [r[key] for r in er]))
        if e in levels:
            pi_total = statistics.median(r["pi_total"] for r in er)
            print(f"  usb_time   level {levels[e]} - pi_total {pi_total:.1f} = {levels[e] - pi_total:.1f} "
                  f"(the two USB legs on the device timeline, origin-free)")
        with_stamps = [r for r in er if "tx_lead" in r]
        if with_stamps:
            print(f"  stamp domain ({len(with_stamps)} impulses matched in the capture):")
            for key in ["tx_lead", "loop", "rx_lag", "stamp_sum"]:
                print(summarise(key, [r[key] for r in with_stamps]))
            print(summarise("pkt_out_ms", [r["pkt_out_ms"] for r in with_stamps], "{:9.3f}"))
            print(summarise("pkt_back_ms", [r["pkt_back_ms"] for r in with_stamps], "{:9.3f}"))
            print(summarise("out_frame", [r["out_frame"] for r in with_stamps], "{:9.0f}"))
            print(summarise("back_frame", [r["back_frame"] for r in with_stamps], "{:9.0f}"))
            starts_tx = sorted(set(r["start_tx"] for r in with_stamps))
            starts_gap = [r["start_gap"] for r in with_stamps]
            print(f"  start_tx   stamp of playback position 0: {starts_tx[:3]}{' ...' if len(starts_tx) > 3 else ''}"
                  f" (mod 48: {sorted(set(s % 48 for s in starts_tx))})")
            print(summarise("start_gap", starts_gap, "{:9.0f}") + "  (start_tx - start_rx)")

    if args.csv:
        keys = sorted(set(k for r in rows for k in r), key=lambda k: (k != "epoch", k))
        with open(args.csv, "w") as fh:
            fh.write(",".join(keys) + "\n")
            for r in rows:
                fh.write(",".join(str(r.get(k, "")) for k in keys) + "\n")
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
