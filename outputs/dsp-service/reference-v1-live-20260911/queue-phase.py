#!/usr/bin/env python3
"""Why a bridge log's sampled tx_queue and its running floor step late in a run.

The once-per-second BRIDGE line prints tx_queue as the last snd_pcm_delay the
audio loop stored (main.cpp, the telemetry block near `have_playback_delays`),
and the telemetry thread copies it out at its own 1 Hz cadence. The RAVENNA
TIC pulls 48 frames every millisecond and the bridge refills 48 on each USB
wake, so the queue is a 48-frame sawtooth inside every millisecond and one
sample of it reads either side of a pull. Which side depends on where the
bridge's wake sits against the tick: the servo prints that as phase_us. The
queue floor (tx_qfloor) is the running minimum over every observation, so it
too is drawn only when an observation lands just after a pull with the
sawtooth at its bottom and a long wake gap behind it.

This script shows both from a log: per 60-row block, the mean of the sampled
tx_queue, the windowed observation mean tx_qmean and the depth mean tx_dmean
(ring plus queue), and how many rows sat within --zone us of the tick wrap;
then every row whose sampled tx_queue is more than --dip frames under the
block's typical value, with its phase_us; then every tx_qfloor step with the
phase_us of the row it landed on.

Usage: queue-phase.py LOG [--zone 100] [--dip 30]
"""
import argparse
import statistics
import sys


def parse(path):
    rows = []
    with open(path, errors="replace") as handle:
        for line in handle:
            if not line.startswith("BRIDGE "):
                continue
            fields = {}
            for token in line.split()[1:]:
                key, sep, value = token.partition("=")
                if sep:
                    fields[key] = value
            try:
                rows.append({
                    "tx_queue": float(fields["tx_queue"]),
                    "tx_qmean": float(fields.get("tx_qmean", "nan")),
                    "tx_dmean": float(fields.get("tx_dmean", "nan")),
                    "tx_qfloor": float(fields["tx_qfloor"]),
                    "phase_us": int(fields.get("phase_us", "-1")),
                })
            except (KeyError, ValueError):
                continue
    return rows


def in_zone(phase, zone):
    return phase >= 0 and (phase < zone or phase > 1000 - zone)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--zone", type=int, default=100,
                        help="microseconds either side of the tick wrap (default 100)")
    parser.add_argument("--dip", type=float, default=30,
                        help="frames under the block median that count as a dip (default 30)")
    args = parser.parse_args()
    rows = parse(args.log)
    if not rows:
        sys.exit(f"no BRIDGE rows in {args.log}")
    print(f"== {args.log}: {len(rows)} BRIDGE rows")
    print("block      tx_queue(sampled)  tx_qmean  tx_dmean  rows_in_wrap_zone  dips")
    dips = []
    for start in range(0, len(rows), 60):
        block = rows[start:start + 60]
        median = statistics.median(r["tx_queue"] for r in block)
        zone_rows = sum(1 for r in block if in_zone(r["phase_us"], args.zone))
        block_dips = [(start + i + 1, r) for i, r in enumerate(block)
                      if r["tx_queue"] < median - args.dip]
        dips.extend(block_dips)
        print(f"{start + 1:4d}-{start + len(block):4d}  {statistics.fmean(r['tx_queue'] for r in block):8.1f}"
              f"  {statistics.fmean(r['tx_qmean'] for r in block):8.1f}"
              f"  {statistics.fmean(r['tx_dmean'] for r in block):8.1f}"
              f"  {zone_rows:5d}             {len(block_dips):3d}")
    zone_dips = sum(1 for _, r in dips if in_zone(r["phase_us"], args.zone))
    print(f"dips: {len(dips)} rows read more than {args.dip:g} under their block median; "
          f"{zone_dips} of them with phase_us within {args.zone} us of the tick wrap")
    normal = [r["phase_us"] for i, r in enumerate(rows) if (i + 1, r) not in dips and r["phase_us"] >= 0]
    dipped = [r["phase_us"] for _, r in dips if r["phase_us"] >= 0]
    if normal:
        print(f"phase_us on the other rows: {min(normal)}-{max(normal)}")
    if dipped:
        print(f"phase_us on the dip rows:   {sorted(dipped)}")
    print("tx_qfloor steps (row, floor, phase_us of that row, phase_us of the row before):")
    previous = None
    for index, row in enumerate(rows):
        if previous is not None and row["tx_qfloor"] != previous["tx_qfloor"]:
            print(f"  row {index + 1}: {previous['tx_qfloor']:.0f} -> {row['tx_qfloor']:.0f}"
                  f"  phase_us {row['phase_us']} (before: {previous['phase_us']})")
        previous = row


if __name__ == "__main__":
    main()
