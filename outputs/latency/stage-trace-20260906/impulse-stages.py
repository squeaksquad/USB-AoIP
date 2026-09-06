#!/usr/bin/env python3
"""Split a bridge session's round trip by stage from its IMPULSE lines.

Reads a full-rate bridge log (or a journal export) carrying the IMPULSE
lines the impulse trace writes (bridge --impulse-trace 1, 2026-09-06), groups
them into impulses (usb-capture, ravenna-playback, ravenna-capture,
usb-playback in signal order), and reports per impulse:

  bridge_tx   usb-capture frame time -> ravenna-playback write      (TX ring dwell)
  tx_queue    ravenna-playback write -> its estimated play time      (TX queue at write)
  aes67       ravenna-playback play time -> ravenna-capture frame    (device, wire, Ferrofish, wire, RAVENNA capture)
  bridge_rx   ravenna-capture frame time -> usb-playback write       (RX ring dwell)
  rx_queue    usb-playback write -> its estimated play time          (RX queue at write)
  pi_total    usb-capture frame time -> usb-playback play time

Frame time for a capture stage is the wake that found the block, minus the
frames between the hit and the block's last frame (the last frame is taken
as fresh at the wake). Play time for a playback stage is the write time plus
the queue depth the bridge last sampled plus the hit's offset in the block;
the depth is a 1 Hz sample, so the two queue terms carry up to a period of
error and pi_total with them. With --level N (the harness's samples at 64
frames, device timeline), the two Pi USB legs together are level - pi_total.
"""
import argparse
import re
import statistics
import sys

STAGES = ["usb-capture", "ravenna-playback", "ravenna-capture", "usb-playback"]
FRAME_NS = 1e9 / 48000.0
LINE = re.compile(r"^IMPULSE (.*)$")


def parse(path):
    events = []
    with open(path, errors="replace") as handle:
        for raw in handle:
            match = LINE.match(raw.strip())
            if not match:
                continue
            fields = {}
            for token in match.group(1).split():
                key, _, value = token.partition("=")
                fields[key] = value
            try:
                events.append({
                    "stage": fields["stage"],
                    "position": int(fields["position"]),
                    "block_frames": int(fields["block_frames"]),
                    "offset": int(fields["offset"]),
                    "depth": int(fields["depth"]),
                    "block_ns": int(fields["block_ns"]),
                    "now_ns": int(fields["now_ns"]),
                    "t_us": int(fields["t_us"]),
                })
            except (KeyError, ValueError):
                continue
    events.sort(key=lambda e: e["now_ns"])
    return events


def stage_times(event):
    """(reference time, play time) in ns for one event."""
    if event["stage"].endswith("capture"):
        frame_ns = event["block_ns"] - (event["block_frames"] - 1 - event["offset"]) * FRAME_NS
        return frame_ns, None
    write_ns = event["block_ns"]
    play_ns = write_ns + (event["depth"] + event["offset"]) * FRAME_NS
    return write_ns, play_ns


def group(events):
    groups, current = [], None
    for event in events:
        if event["stage"] == STAGES[0]:
            if current and len(current) == 4:
                groups.append(current)
            current = {event["stage"]: event}
            continue
        if current is None:
            continue
        expected = STAGES[len(current)]
        if event["stage"] == expected and event["now_ns"] - current[STAGES[0]]["now_ns"] < 200_000_000:
            current[event["stage"]] = event
        else:
            current = None
    if current and len(current) == 4:
        groups.append(current)
    return groups


def summarise(name, values, unit_scale, unit):
    if not values:
        print(f"  {name:<10} no data")
        return
    values = sorted(values)
    median = statistics.median(values)
    print(f"  {name:<10} median {median * unit_scale:9.3f} {unit}  min {values[0] * unit_scale:9.3f}  "
          f"max {values[-1] * unit_scale:9.3f}  n {len(values)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log")
    parser.add_argument("--level", type=int, help="harness samples at 64 frames for this session (device timeline)")
    parser.add_argument("--after-us", type=int, default=0, help="ignore impulses before this bridge t_us")
    parser.add_argument("--csv", help="write per-impulse rows here")
    args = parser.parse_args()

    events = parse(args.log)
    by_stage = {stage: sum(1 for e in events if e["stage"] == stage) for stage in STAGES}
    groups = [g for g in group(events) if g[STAGES[0]]["t_us"] >= args.after_us]
    print(f"{args.log}: {len(events)} IMPULSE lines, per stage {by_stage}, {len(groups)} complete impulses")
    if not groups:
        sys.exit(1)

    rows = []
    for g in groups:
        t1, _ = stage_times(g["usb-capture"])
        t2, t2p = stage_times(g["ravenna-playback"])
        t3, _ = stage_times(g["ravenna-capture"])
        t4, t4p = stage_times(g["usb-playback"])
        rows.append({
            "t_us": g["usb-capture"]["t_us"],
            "bridge_tx": t2 - t1,
            "tx_queue": t2p - t2,
            "aes67": t3 - t2p,
            "bridge_rx": t4 - t3,
            "rx_queue": t4p - t4,
            "pi_total": t4p - t1,
            "pos_tx": g["ravenna-playback"]["position"] - g["usb-capture"]["position"],
            "pos_rx": g["usb-playback"]["position"] - g["ravenna-capture"]["position"],
            "tx_depth": g["ravenna-playback"]["depth"],
            "rx_depth": g["usb-playback"]["depth"],
            "usbcap_backlog": g["usb-capture"]["depth"],
            "ravcap_backlog": g["ravenna-capture"]["depth"],
        })

    print("times (ms; 48 samples = 1 ms):")
    for key in ["bridge_tx", "tx_queue", "aes67", "bridge_rx", "rx_queue", "pi_total"]:
        summarise(key, [r[key] for r in rows], 1e-6, "ms")
    print("same, in samples:")
    for key in ["bridge_tx", "tx_queue", "aes67", "bridge_rx", "rx_queue", "pi_total"]:
        summarise(key, [r[key] for r in rows], 48000e-9, "smp")
    print("positions and depths (frames):")
    for key in ["pos_tx", "pos_rx", "tx_depth", "rx_depth", "usbcap_backlog", "ravcap_backlog"]:
        summarise(key, [r[key] for r in rows], 1.0, "fr")
    if args.level is not None:
        pi_total = statistics.median(r["pi_total"] for r in rows) * 48000e-9
        print(f"harness level {args.level} - pi_total {pi_total:.1f} = USB legs together {args.level - pi_total:.1f} samples "
              f"({(args.level - pi_total) / 48:.2f} ms), queue terms from 1 Hz depth samples")
    if args.csv:
        with open(args.csv, "w") as out:
            keys = list(rows[0].keys())
            out.write(",".join(keys) + "\n")
            for r in rows:
                out.write(",".join(str(r[k]) for k in keys) + "\n")
        print(f"wrote {args.csv}")


if __name__ == "__main__":
    main()
