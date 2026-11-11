#!/usr/bin/env python3
"""Measure the magnitude response of each output's PEQ through CamillaDSP.

A tone per frequency would need a settling time that high-Q bands at low
frequencies make impractical. Instead this feeds one impulse, captures the
impulse response, and evaluates its DFT at the frequencies of interest: the
whole magnitude response from one short run, with no settling to wait out.

Output is read as F64 so the measurement carries no quantisation of its own.
Truncating an IIR response leaks a little, so the capture is long enough that
every band under test has decayed to a fraction of a percent first.

Offline: no ALSA device is opened. It reads and writes files.
"""

import argparse
import array
import cmath
import json
import math
import subprocess
import sys
from pathlib import Path

CHANNELS = 16


def write_impulse(path, frames, amplitude, lead):
    """One impulse on every channel at `lead`; routing keeps the outputs apart."""
    block = array.array("d", [0.0] * (frames * CHANNELS))
    for channel in range(CHANNELS):
        block[lead * CHANNELS + channel] = amplitude
    with open(path, "wb") as out:
        block.tofile(out)


def read_f64(path):
    values = array.array("d")
    with open(path, "rb") as handle:
        values.frombytes(handle.read())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def response_at(samples, channel, frames, rate, freqs, lead):
    """|H(f)| for one channel, by evaluating the DFT of its impulse response.

    A rotating phasor rather than a trig call per sample; in double precision
    its drift over this many samples is far below the tolerance being checked.
    """
    out = []
    for freq in freqs:
        step = cmath.exp(complex(0.0, -2.0 * math.pi * freq / rate))
        phasor = complex(1.0, 0.0)
        total = complex(0.0, 0.0)
        for n in range(lead, frames):
            total += samples[n * CHANNELS + channel] * phasor
            phasor *= step
        out.append(abs(total))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--camilladsp", required=True)
    parser.add_argument("--in", dest="input_path", required=True)
    parser.add_argument("--out", dest="output_path", required=True)
    parser.add_argument("--frames", type=int, default=16384)
    parser.add_argument("--lead", type=int, default=64)
    parser.add_argument("--amplitude", type=float, default=0.25)
    parser.add_argument("--rate", type=float, default=48000.0)
    parser.add_argument("--freqs", required=True,
                        help="comma-separated frequencies in Hz")
    arguments = parser.parse_args()

    freqs = [float(v) for v in arguments.freqs.split(",") if v.strip()]
    write_impulse(arguments.input_path, arguments.frames, arguments.amplitude, arguments.lead)
    Path(arguments.output_path).unlink(missing_ok=True)
    done = subprocess.run([arguments.camilladsp, arguments.config],
                          capture_output=True, text=True, timeout=600)
    if not Path(arguments.output_path).exists():
        print(done.stderr[-2000:], file=sys.stderr)
        return 1

    samples = read_f64(arguments.output_path)
    frames = min(arguments.frames, len(samples) // CHANNELS)
    result = {"freqs": freqs, "frames": frames, "channels": [], "usedFrames": []}
    floor = arguments.amplitude * 1e-10
    for channel in range(CHANNELS):
        # Most of these responses are over in a few hundred samples; only the
        # low-frequency high-Q ones need the whole capture. Summing past the
        # point where the response has died costs time and adds nothing.
        last = arguments.lead
        for n in range(frames - 1, arguments.lead - 1, -1):
            if abs(samples[n * CHANNELS + channel]) > floor:
                last = min(frames, n + 64)
                break
        result["usedFrames"].append(last - arguments.lead)
        magnitudes = response_at(samples, channel, last, arguments.rate,
                                 freqs, arguments.lead)
        # Relative to the impulse, so an unshaped path reads 0 dB.
        result["channels"].append([
            round(20 * math.log10(m / arguments.amplitude), 4) if m > 0 else None
            for m in magnitudes])
        # A response still ringing at the end of the capture biases its own
        # measurement, and does so worst at the band centre where the error is
        # least obvious. Say so rather than let a short capture read as a
        # disagreement with the model: a +18 dB Q6 band at 40 Hz needs about
        # 110,000 samples to decay, and at 16,384 it reads 0.62 dB low.
        tail = sum(abs(samples[n * CHANNELS + channel])
                   for n in range(max(arguments.lead, frames - 256), frames))
        tail /= arguments.amplitude
        result.setdefault("tailSum", []).append(round(tail, 8))
        result.setdefault("truncated", []).append(bool(tail > 1e-6))
    if any(result["truncated"]):
        short = [i + 1 for i, v in enumerate(result["truncated"]) if v]
        result["warning"] = (
            f"Outputs {short} were still ringing at the end of the capture; "
            f"their magnitudes are biased low. Re-run with more --frames.")
        print(result["warning"], file=sys.stderr)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
