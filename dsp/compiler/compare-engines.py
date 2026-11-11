#!/usr/bin/env python3
"""Compare two engines' output of the same input, sample by sample.

The harnesses compare derived quantities -- a magnitude, an event, a verdict --
which is what makes them readable, but it also means two engines could differ
in a way no harness happens to look at. This compares the raw output files
directly, which leaves nowhere for a difference to hide.

Per channel it reports the peak of the reference, the largest absolute
difference, and that difference relative to the reference's own peak. The last
is the number that matters: a difference 100 dB below the signal that produced
it is a precision floor, and a difference near the signal is a disagreement.

Offline: it reads two files and prints. It runs nothing.
"""

import argparse
import array
import json
import math
import sys

CHANNELS = 16


def read(path, fmt):
    values = array.array("d" if fmt == "f64le" else "i")
    with open(path, "rb") as handle:
        values.frombytes(handle.read())
    if sys.byteorder != "little":
        values.byteswap()
    if fmt == "f64le":
        return values
    scale = 1.0 / 2147483648.0
    return array.array("d", [value * scale for value in values])


def to_db(value):
    return round(20 * math.log10(value), 3) if value > 0 else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference")
    parser.add_argument("candidate")
    parser.add_argument("--format", default="f64le", choices=["f64le", "s32le"])
    parser.add_argument("--label-reference", default="reference")
    parser.add_argument("--label-candidate", default="candidate")
    arguments = parser.parse_args()

    left = read(arguments.reference, arguments.format)
    right = read(arguments.candidate, arguments.format)
    frames = min(len(left), len(right)) // CHANNELS
    result = {
        "format": arguments.format,
        "reference": arguments.label_reference,
        "candidate": arguments.label_candidate,
        "frames": frames,
        "referenceFrames": len(left) // CHANNELS,
        "candidateFrames": len(right) // CHANNELS,
        "channels": [],
    }
    if len(left) != len(right):
        result["warning"] = (
            f"lengths differ: {len(left) // CHANNELS} vs {len(right) // CHANNELS} frames; "
            "comparing the overlap")

    worst_relative = None
    for channel in range(CHANNELS):
        peak = 0.0
        worst = 0.0
        worst_at = None
        differing = 0
        for frame in range(frames):
            index = frame * CHANNELS + channel
            a, b = left[index], right[index]
            peak = max(peak, abs(a))
            difference = abs(a - b)
            if difference > 0:
                differing += 1
            if difference > worst:
                worst, worst_at = difference, frame
        relative = to_db(worst / peak) if peak > 0 and worst > 0 else None
        result["channels"].append({
            "channel": channel + 1,
            "peakDbfs": to_db(peak),
            "worstDiffDbfs": to_db(worst),
            "worstDiffRelDb": relative,
            "worstAtFrame": worst_at,
            "differingSamples": differing,
            "totalSamples": frames,
        })
        if peak > 0 and relative is not None:
            if worst_relative is None or relative > worst_relative[0]:
                worst_relative = (relative, channel + 1)

    result["worstRelativeDb"] = worst_relative[0] if worst_relative else None
    result["worstRelativeChannel"] = worst_relative[1] if worst_relative else None
    result["identical"] = all(entry["differingSamples"] == 0 for entry in result["channels"])
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
