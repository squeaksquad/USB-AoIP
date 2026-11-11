#!/usr/bin/env python3
"""Measure the bass matrix through CamillaDSP, file to file.

Impulses cannot check the sub path: an 80 Hz LR4 low-pass rings far past any
window short enough to keep one input's response from bleeding into the next.
So this drives a tone well below the crossover, where the low-pass is within a
few hundredths of a decibel of unity, and measures steady-state level.

The signal is one segment per input, each carrying the tone on that input alone,
then a final segment with several inputs driven in phase. Segment by segment
that isolates every matrix entry; the last segment checks that coherent summing
matches the ceiling the compiler reports.

Offline: no ALSA device is opened. It reads and writes files.
"""

import argparse
import array
import json
import math
import subprocess
import sys
from pathlib import Path

CHANNELS = 16
FULL = 2 ** 31
RATE = 48000


def build_signal(path, segments, seg_frames, freq, amplitude):
    """One segment per entry in `segments`; each entry lists the inputs driven."""
    scale = int(amplitude * (FULL - 1))
    frame = array.array("i", [0] * CHANNELS)
    with open(path, "wb") as out:
        for driven in segments:
            block = array.array("i")
            for n in range(seg_frames):
                for channel in range(CHANNELS):
                    frame[channel] = (
                        int(scale * math.sin(2 * math.pi * freq * n / RATE))
                        if channel in driven else 0)
                block.extend(frame)
            block.tofile(out)


def segment_levels(path, segment_count, seg_frames, settle_frames):
    """Peak-equivalent level per output per segment, as a ratio of full scale."""
    raw = array.array("i")
    with open(path, "rb") as handle:
        raw.frombytes(handle.read())
    if sys.byteorder != "little":
        raw.byteswap()
    frames = len(raw) // CHANNELS
    levels = []
    for segment in range(segment_count):
        start = segment * seg_frames + settle_frames
        stop = min((segment + 1) * seg_frames, frames)
        if start >= stop:
            levels.append([None] * CHANNELS)
            continue
        sums = [0.0] * CHANNELS
        for n in range(start, stop):
            base = n * CHANNELS
            for channel in range(CHANNELS):
                value = raw[base + channel] / FULL
                sums[channel] += value * value
        count = stop - start
        # A sine's RMS is A/sqrt(2); report A so it compares to a gain directly.
        levels.append([math.sqrt(2 * total / count) for total in sums])
    return levels


def to_db(ratio):
    return round(20 * math.log10(ratio), 3) if ratio and ratio > 1e-12 else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--camilladsp", required=True)
    parser.add_argument("--in", dest="input_path", required=True)
    parser.add_argument("--out", dest="output_path", required=True)
    parser.add_argument("--freq", type=float, default=20.0)
    parser.add_argument("--amplitude", type=float, default=0.25)
    parser.add_argument("--segment-ms", type=float, default=250.0)
    parser.add_argument("--settle-ms", type=float, default=150.0)
    parser.add_argument("--sum-inputs", default="",
                        help="comma-separated inputs driven together in the last segment")
    arguments = parser.parse_args()

    seg_frames = int(arguments.segment_ms / 1000 * RATE)
    settle_frames = int(arguments.settle_ms / 1000 * RATE)
    segments = [{i} for i in range(CHANNELS)]
    summed = {int(v) for v in arguments.sum_inputs.split(",") if v.strip() != ""}
    if summed:
        segments.append(summed)

    build_signal(arguments.input_path, segments, seg_frames,
                 arguments.freq, arguments.amplitude)
    Path(arguments.output_path).unlink(missing_ok=True)
    done = subprocess.run([arguments.camilladsp, arguments.config],
                          capture_output=True, text=True, timeout=300)
    if not Path(arguments.output_path).exists():
        print(done.stderr[-2000:], file=sys.stderr)
        return 1

    levels = segment_levels(arguments.output_path, len(segments), seg_frames, settle_frames)
    drive_db = to_db(arguments.amplitude)
    result = {
        "freq": arguments.freq,
        "driveDb": drive_db,
        "segmentFrames": seg_frames,
        "settleFrames": settle_frames,
        "segments": [],
    }
    for index, (driven, row) in enumerate(zip(segments, levels)):
        result["segments"].append({
            "segment": index,
            "inputs": sorted(driven),
            # Level relative to the drive, so a 0 dB send with a unity low-pass
            # reads as the headroom trim and nothing else.
            "outputsDb": [None if v is None else
                          (to_db(v / arguments.amplitude) if v > 1e-9 else None)
                          for v in row],
        })
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
