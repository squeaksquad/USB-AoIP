#!/usr/bin/env python3
"""Measure what a compiled configuration costs the Pi to run, file to file.

The question step 4 has to answer before any of its architecture matters: can
this Pi carry 16 outputs of PEQ plus the crossovers at 48 kHz, and with how much
margin. Everything about where the engine sits relative to the bridge is a
different problem if the answer is "barely".

Method. CamillaDSP reads a raw file as fast as it can, so processing N seconds
of audio and timing it gives a throughput. The trap is that a fast
configuration finishes a short file in less time than the process takes to
start, and the measurement becomes a measurement of process startup. So this
runs two durations and reports the *marginal* cost of the extra audio between
them, which cancels the fixed cost exactly rather than hoping it is small.

The headline is CPU seconds per audio second: the fraction of one core the
configuration needs. CamillaDSP processes on one thread, so 1.0 means one core
fully committed and no margin at all.

What this is not. File to file has no period deadlines, no interrupt
contention and no other process competing, and the Pi here is otherwise idle.
A configuration that cannot pass this cannot possibly run in real time; one
that passes it comfortably still has to be shown to hold a deadline. This is a
necessary condition and an upper bound on throughput, not a latency result.

Offline: no ALSA device is opened. It reads and writes files.
"""

import argparse
import array
import json
import math
import os
import resource
import statistics
import subprocess
import sys
import time
from pathlib import Path

CHANNELS = 16
RATE = 48000
FULL = 2 ** 31 - 1


def write_signal(path, seconds, amplitude=0.25):
    """A different tone per channel, so no channel is silent.

    Silence is the wrong signal for this: an IIR filter fed zeros settles into
    denormal numbers, and on hardware that traps them the cost measured would
    be the denormal handling rather than the filtering.
    """
    frames = int(seconds * RATE)
    wanted = frames * CHANNELS * 4
    # These files are tens of megabytes and cost more to generate in Python
    # than the engine takes to process them, so a sweep reuses one per
    # duration rather than rewriting it for every configuration.
    if Path(path).exists() and Path(path).stat().st_size == wanted:
        return frames
    scale = amplitude * FULL
    block = array.array("i", [0] * (frames * CHANNELS))
    # Spread across the band so the crossovers and the PEQ bands all see signal.
    freqs = [55.0 * (2 ** (n / 3.0)) for n in range(CHANNELS)]
    for channel, freq in enumerate(freqs):
        step = 2 * math.pi * freq / RATE
        # Written a channel at a time through an extended slice: the same
        # arithmetic, without sixteen million interpreter round trips.
        block[channel::CHANNELS] = array.array(
            "i", [int(scale * math.sin(step * n)) for n in range(frames)])
    with open(path, "wb") as out:
        block.tofile(out)
    return frames


def thermal_state():
    """Enough of the Pi's state to know whether a slow run was a hot one."""
    def read(path, cast=int):
        try:
            return cast(Path(path).read_text().strip())
        except Exception:
            return None
    return {
        "tempC": (lambda v: v / 1000.0 if v is not None else None)(
            read("/sys/class/thermal/thermal_zone0/temp")),
        "governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", str),
        "khz": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
        "loadavg": read("/proc/loadavg", str),
    }


def timed_run(camilladsp, config, output_path):
    """One engine run, with wall time and the child's own CPU time."""
    Path(output_path).unlink(missing_ok=True)
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    done = subprocess.run([camilladsp, config], capture_output=True, text=True,
                          timeout=1800)
    wall = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if not Path(output_path).exists():
        return None, done
    return {
        "wall": wall,
        "user": after.ru_utime - before.ru_utime,
        "sys": after.ru_stime - before.ru_stime,
    }, done


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("short_config", help="configuration reading the short input")
    parser.add_argument("long_config", help="the same configuration, long input")
    parser.add_argument("--camilladsp", required=True)
    parser.add_argument("--short-in", required=True)
    parser.add_argument("--short-out", required=True)
    parser.add_argument("--long-in", required=True)
    parser.add_argument("--long-out", required=True)
    parser.add_argument("--short-seconds", type=float, default=4.0)
    parser.add_argument("--long-seconds", type=float, default=16.0)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--label", default="")
    parser.add_argument("--keep-input", action="store_true")
    arguments = parser.parse_args()

    result = {"label": arguments.label, "repeat": arguments.repeat,
              "shortSeconds": arguments.short_seconds,
              "longSeconds": arguments.long_seconds,
              "before": thermal_state(), "runs": {}}

    for name, config, in_path, out_path, seconds in (
            ("short", arguments.short_config, arguments.short_in,
             arguments.short_out, arguments.short_seconds),
            ("long", arguments.long_config, arguments.long_in,
             arguments.long_out, arguments.long_seconds)):
        write_signal(in_path, seconds)
        samples = []
        for _ in range(arguments.repeat):
            timing, done = timed_run(arguments.camilladsp, config, out_path)
            if timing is None:
                print(done.stderr[-2000:], file=sys.stderr)
                return 1
            samples.append(timing)
        result["runs"][name] = {
            "seconds": seconds,
            "wall": [round(s["wall"], 4) for s in samples],
            "cpu": [round(s["user"] + s["sys"], 4) for s in samples],
            "wallMin": round(min(s["wall"] for s in samples), 4),
            "cpuMin": round(min(s["user"] + s["sys"] for s in samples), 4),
        }
        if not arguments.keep_input:
            Path(in_path).unlink(missing_ok=True)
            Path(out_path).unlink(missing_ok=True)

    # The difference between the two durations is the cost of the audio alone;
    # process startup, config parsing and filter construction fall out of it.
    # Minimum rather than mean: the fastest run is the one least disturbed by
    # something else on the machine.
    audio = arguments.long_seconds - arguments.short_seconds
    cpu = result["runs"]["long"]["cpuMin"] - result["runs"]["short"]["cpuMin"]
    wall = result["runs"]["long"]["wallMin"] - result["runs"]["short"]["wallMin"]
    result["marginal"] = {
        "audioSeconds": audio,
        "cpuSeconds": round(cpu, 4),
        "wallSeconds": round(wall, 4),
        # The headline: how much of one core this configuration needs.
        "coresNeeded": round(cpu / audio, 5),
        "realtimeFactorCpu": round(audio / cpu, 2) if cpu > 0 else None,
        "realtimeFactorWall": round(audio / wall, 2) if wall > 0 else None,
    }
    result["fixedCostSeconds"] = round(
        result["runs"]["short"]["cpuMin"] - cpu * arguments.short_seconds / audio, 4)
    result["after"] = thermal_state()
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
