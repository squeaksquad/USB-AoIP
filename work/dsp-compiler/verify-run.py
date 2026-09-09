#!/usr/bin/env python3
"""Run one compiled configuration through CamillaDSP file-to-file and measure it.

Offline verification: no ALSA device is opened and no service is touched. It
writes a staggered-impulse input, runs the engine, and reports where energy
landed on each output, so routing, delay, polarity, gain and mute can be checked
against the preset that produced the configuration.

Impulse for input i sits at START + i*STRIDE. With crossovers off there is no
ringing, so each input owns a clean window and every output's content can be
attributed to the input that caused it.
"""

import argparse
import json
import struct
import subprocess
import sys
from pathlib import Path

CHANNELS = 16
FULL = 2 ** 31
AMPLITUDE = 2 ** 30          # -6.02 dBFS, so a +6 dB path would still not clip
START = 1000
STRIDE = 1000
FRAMES = START + CHANNELS * STRIDE + 2000


def write_input(path):
    frame = bytearray(CHANNELS * 4)
    with open(path, "wb") as out:
        for n in range(FRAMES):
            silent = True
            for channel in range(CHANNELS):
                value = AMPLITUDE if n == START + channel * STRIDE else 0
                if value:
                    silent = False
                struct.pack_into("<i", frame, channel * 4, value)
            out.write(frame)
            if not silent:
                for channel in range(CHANNELS):
                    struct.pack_into("<i", frame, channel * 4, 0)


def read_output(path):
    raw = Path(path).read_bytes()
    frames = len(raw) // (CHANNELS * 4)
    values = struct.unpack_from("<%di" % (frames * CHANNELS), raw, 0)
    return [values[n * CHANNELS:(n + 1) * CHANNELS] for n in range(frames)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--camilladsp", required=True)
    parser.add_argument("--in", dest="input_path", required=True)
    parser.add_argument("--out", dest="output_path", required=True)
    parser.add_argument("--threshold", type=float, default=1e-4)
    arguments = parser.parse_args()

    write_input(arguments.input_path)
    Path(arguments.output_path).unlink(missing_ok=True)
    done = subprocess.run([arguments.camilladsp, arguments.config],
                          capture_output=True, text=True, timeout=120)
    if not Path(arguments.output_path).exists():
        print(done.stderr[-2000:], file=sys.stderr)
        return 1

    frames = read_output(arguments.output_path)
    floor = AMPLITUDE * arguments.threshold
    result = {"frames": len(frames), "amplitude": AMPLITUDE, "outputs": []}
    for channel in range(CHANNELS):
        hits = []
        for n, frame in enumerate(frames):
            value = frame[channel]
            if abs(value) > floor:
                hits.append((n, value))
        # Group contiguous non-zero runs into events, keeping the peak of each.
        events = []
        for n, value in hits:
            if events and n - events[-1]["last"] <= 2:
                events[-1]["last"] = n
                if abs(value) > abs(events[-1]["peak"]):
                    events[-1]["peak"] = value
                    events[-1]["at"] = n
            else:
                events.append({"at": n, "last": n, "peak": value})
        result["outputs"].append({
            "channel": channel,
            "events": [{
                "sample": e["at"],
                "fromInput": (e["at"] - START) // STRIDE if e["at"] >= START else None,
                "ratio": round(e["peak"] / AMPLITUDE, 6),
                "db": round(20 * (abs(e["peak"]) / AMPLITUDE and
                                  __import__("math").log10(abs(e["peak"]) / AMPLITUDE)), 3),
                "inverted": e["peak"] < 0,
            } for e in events],
        })
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
