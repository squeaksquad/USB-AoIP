#!/usr/bin/env python3
"""Measure what CamillaDSP does at and past full scale, file to file.

The compiler reports a coherent worst-case ceiling and warns when an output can
exceed 0 dBFS, but every earlier verification was run deliberately below full
scale, so what the engine does when a preset is driven past it was untested.
There are two very different answers -- saturate, or wrap -- and the difference
between them is the difference between a loud passage sounding hard and a loud
passage turning into full-scale noise. The bridge had exactly this bug once.

Three things are measured:

  * Bit transparency of a unity path, including at +/- full scale. An integer
    range is asymmetric: the most negative sample has no positive counterpart,
    so a unity path and an inverted unity path are different tests.
  * Gain paths driven past 0 dBFS, against the value the gain says to expect.
    Saturation lands on the rail; wrapping lands on the far side of it.
  * A path driven past 0 dBFS by coherent summing rather than by gain, checked
    against an F64 run of the same preset that shows the intended value before
    the integer conversion.

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
MAX_S32 = 2 ** 31 - 1
MIN_S32 = -(2 ** 31)

def rails(bits):
    """Exact values worth putting through a unity path, on a `bits` grid.

    The rails are where an off-by-one or an asymmetric scale shows up, so they
    have to be values the pipeline under test can actually hold. A pipeline
    carrying float32 samples has a 24-bit mantissa: it represents every 24-bit
    sample exactly and is one bit short of a 32-bit container. Asking it for
    bit transparency on 32-bit rails is asking a question with no right answer,
    and the +/-1 LSB it returns says nothing about the converter.

    CamillaDSP processes in double and answers at 32; the bridge carries float
    and answers at 24, which is the width its devices actually run.
    """
    step = 1 << (32 - bits)
    top = ((MAX_S32 // step) * step)
    bottom = MIN_S32
    return [0, top, bottom, top - step, bottom + step, step, -step,
            top, bottom, (top // 2 // step) * step, (bottom // 2 // step) * step, 0]


def build_input(int_path, float_path, rail_frames, tone_frames, tones, amplitude,
                bits=32):
    """The same signal in both formats: rails first, then a full-scale tone.

    Writing both rather than converting one config's format keeps each run on a
    configuration the compiler actually emitted.
    """
    total = rail_frames + tone_frames
    step = 1 << (32 - bits)
    grid = rails(bits)
    ints = array.array("i", [0] * (total * CHANNELS))
    floats = array.array("d", [0.0] * (total * CHANNELS))
    for n in range(rail_frames):
        value = grid[n % len(grid)]
        for channel in range(CHANNELS):
            ints[n * CHANNELS + channel] = value
            floats[n * CHANNELS + channel] = value / -MIN_S32
    for n in range(tone_frames):
        frame = rail_frames + n
        for channel in range(CHANNELS):
            freq = tones.get(channel, tones["default"])
            value = amplitude * math.sin(2 * math.pi * freq * n / 48000.0)
            # Round to the integer grid once, then use that same number as the
            # float reference, so the two runs are given identical signals.
            quantised = max(MIN_S32, min(MAX_S32, int(round(value * -MIN_S32))))
            # Onto the same grid as the rails, so the whole signal is
            # representable in the pipeline under test.
            quantised = (quantised // step) * step
            ints[frame * CHANNELS + channel] = quantised
            floats[frame * CHANNELS + channel] = quantised / -MIN_S32
    with open(int_path, "wb") as out:
        ints.tofile(out)
    with open(float_path, "wb") as out:
        floats.tofile(out)
    return ints, floats, total


def read_ints(path):
    values = array.array("i")
    with open(path, "rb") as handle:
        values.frombytes(handle.read())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def read_floats(path):
    values = array.array("d")
    with open(path, "rb") as handle:
        values.frombytes(handle.read())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def run_engine(camilladsp, config, output_path, timeout=600):
    Path(output_path).unlink(missing_ok=True)
    done = subprocess.run([camilladsp, config], capture_output=True, text=True,
                          timeout=timeout)
    return done, Path(output_path).exists()


def classify(actual, intended):
    """What the engine did with a sample whose intended value will not fit."""
    if intended > MAX_S32:
        if actual == MAX_S32:
            return "saturated"
        # Wrapping is the failure worth naming: the sample comes back on the
        # far side of the range, so a positive peak reads as a negative one.
        return "wrapped" if actual < 0 else "other"
    if intended < MIN_S32:
        if actual == MIN_S32:
            return "saturated"
        return "wrapped" if actual > 0 else "other"
    return "in range"


def analyse_gain_path(ints_in, ints_out, source, dest, gain_db, invert, total):
    """A path whose intended value is arithmetic: input times a gain."""
    scale = 10 ** (gain_db / 20.0) * (-1 if invert else 1)
    stats = {"source": source + 1, "gainDb": gain_db, "invert": invert,
             "verdicts": {}, "examples": [], "maxValue": 0, "minValue": 0}
    for n in range(total):
        actual = ints_out[n * CHANNELS + dest]
        intended = ints_in[n * CHANNELS + source] * scale
        verdict = classify(actual, intended)
        stats["verdicts"][verdict] = stats["verdicts"].get(verdict, 0) + 1
        stats["maxValue"] = max(stats["maxValue"], actual)
        stats["minValue"] = min(stats["minValue"], actual)
        if verdict in ("wrapped", "other") and len(stats["examples"]) < 8:
            stats["examples"].append({"frame": n, "in": ints_in[n * CHANNELS + source],
                                      "intended": round(intended, 1), "out": actual})
    return stats


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="compiled configuration writing S32_LE")
    parser.add_argument("--camilladsp", required=True)
    parser.add_argument("--in", dest="int_in", required=True)
    parser.add_argument("--out", dest="int_out", required=True)
    parser.add_argument("--float-config", help="the same preset compiled to F64")
    parser.add_argument("--float-in", dest="float_in")
    parser.add_argument("--float-out", dest="float_out")
    parser.add_argument("--rail-frames", type=int, default=240)
    parser.add_argument("--tone-frames", type=int, default=48000)
    parser.add_argument("--amplitude", type=float, default=1.0)
    parser.add_argument("--unity", default="1,1",
                        help="OUT,IN — a 1-based unity path to check for bit transparency")
    parser.add_argument("--inverted", default="5,8",
                        help="OUT,IN — a 1-based unity path with the polarity inverted")
    parser.add_argument("--gain-path", action="append", default=[],
                        help="OUT,IN,GAINDB — a 1-based output driven past full scale by gain")
    parser.add_argument("--sum-path", action="append", default=[],
                        help="OUT — a 1-based output driven past full scale by summing")
    parser.add_argument("--low-tone-inputs", default="4,5,6,7",
                        help="1-based inputs fed 20 Hz instead of 997 Hz, for bass branches")
    parser.add_argument("--sample-bits", type=int, default=32, choices=[16, 24, 32],
                        help="the grid the test signal sits on; 24 for a float32 pipeline")
    arguments = parser.parse_args()
    if arguments.sum_path and not (arguments.float_config and arguments.float_in
                                   and arguments.float_out):
        parser.error("--sum-path needs --float-config, --float-in and --float-out")

    def pair(text):
        out_index, in_index = (int(v) for v in text.split(","))
        return out_index - 1, in_index - 1

    # A bass branch always carries a low-pass, so a path that reaches its output
    # by summing has to be driven inside one. 20 Hz costs 0.0001 dB at the
    # 250 Hz corner these presets use, far below anything measured here.
    tones = {"default": 997.0}
    for value in arguments.low_tone_inputs.split(","):
        if value.strip():
            tones[int(value) - 1] = 20.0

    float_in = arguments.float_in or f"{arguments.int_in}.f64"
    ints_in, _, total = build_input(
        arguments.int_in, float_in, arguments.rail_frames,
        arguments.tone_frames, tones, arguments.amplitude, arguments.sample_bits)

    done, ok = run_engine(arguments.camilladsp, arguments.config, arguments.int_out)
    if not ok:
        print(done.stderr[-2000:], file=sys.stderr)
        return 1
    ints_out = read_ints(arguments.int_out)
    total = min(total, len(ints_out) // CHANNELS)

    result = {
        "frames": total, "railFrames": arguments.rail_frames,
        "amplitude": arguments.amplitude, "sampleBits": arguments.sample_bits,
        # The engine's own words. If it counts clipped samples this is where
        # that shows up, and an engine that says nothing is itself a finding.
        "engineStderr": done.stderr[-4000:],
    }

    # Bit transparency. The integer range is asymmetric, so the inverted path is
    # a separate question from the plain one and gets its own entry.
    unity_out, unity_in = pair(arguments.unity)
    entry = {"output": unity_out + 1, "input": unity_in + 1,
             "compared": 0, "matched": 0, "mismatches": []}
    for n in range(total):
        expected = ints_in[n * CHANNELS + unity_in]
        actual = ints_out[n * CHANNELS + unity_out]
        entry["compared"] += 1
        if actual == expected:
            entry["matched"] += 1
        elif len(entry["mismatches"]) < 12:
            entry["mismatches"].append({"frame": n, "in": expected, "out": actual,
                                        "deltaLsb": actual - expected})
    entry["bitTransparent"] = entry["matched"] == entry["compared"]
    result["unity"] = entry

    inv_out, inv_in = pair(arguments.inverted)
    entry = {"output": inv_out + 1, "input": inv_in + 1,
             "compared": 0, "matched": 0, "mismatches": [], "verdicts": {}}
    for n in range(total):
        source_value = ints_in[n * CHANNELS + inv_in]
        intended = -source_value
        actual = ints_out[n * CHANNELS + inv_out]
        verdict = classify(actual, intended)
        entry["verdicts"][verdict] = entry["verdicts"].get(verdict, 0) + 1
        entry["compared"] += 1
        if actual == max(MIN_S32, min(MAX_S32, intended)):
            entry["matched"] += 1
        elif len(entry["mismatches"]) < 12:
            entry["mismatches"].append({"frame": n, "in": source_value,
                                        "intended": intended, "out": actual,
                                        "verdict": verdict})
    entry["saturatesCorrectly"] = entry["matched"] == entry["compared"]
    result["invertedUnity"] = entry

    result["gainPaths"] = []
    for spec in arguments.gain_path:
        out_index, in_index, gain_db = spec.split(",")
        result["gainPaths"].append(analyse_gain_path(
            ints_in, ints_out, int(in_index) - 1, int(out_index) - 1,
            float(gain_db), False, total))

    # A summing path's intended value is not arithmetic on one input -- it has
    # been through a low-pass -- so the F64 run of the same preset supplies it.
    result["sumPaths"] = []
    if arguments.sum_path:
        float_done, float_ok = run_engine(
            arguments.camilladsp, arguments.float_config, arguments.float_out)
        if not float_ok:
            print(float_done.stderr[-2000:], file=sys.stderr)
            return 1
        floats_out = read_floats(arguments.float_out)
        result["floatEngineStderr"] = float_done.stderr[-2000:]
        for spec in arguments.sum_path:
            dest = int(spec) - 1
            stats = {"output": dest + 1, "verdicts": {}, "examples": [],
                     "peakInternal": 0.0, "maxValue": 0, "minValue": 0}
            for n in range(min(total, len(floats_out) // CHANNELS)):
                actual = ints_out[n * CHANNELS + dest]
                internal = floats_out[n * CHANNELS + dest]
                intended = internal * -MIN_S32
                verdict = classify(actual, intended)
                stats["verdicts"][verdict] = stats["verdicts"].get(verdict, 0) + 1
                stats["peakInternal"] = max(stats["peakInternal"], abs(internal))
                stats["maxValue"] = max(stats["maxValue"], actual)
                stats["minValue"] = min(stats["minValue"], actual)
                if verdict in ("wrapped", "other") and len(stats["examples"]) < 8:
                    stats["examples"].append({"frame": n, "internal": round(internal, 6),
                                              "intended": round(intended, 1),
                                              "out": actual})
            stats["peakInternalDbfs"] = (round(20 * math.log10(stats["peakInternal"]), 3)
                                         if stats["peakInternal"] > 0 else None)
            result["sumPaths"].append(stats)

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
