#!/usr/bin/env python3
"""Check the bridge's monitor block (MonitorGains) file to file, against an
independent implementation of the ramp arithmetic its header documents.

The monitor block is one ramped gain per output, after the DSP stage. What
has to hold, and what this measures:

  (a) the samples are exactly the documented arithmetic: per channel the gain
      is accumulated by repeated addition of (target - gain) / N, lands on the
      target on the Nth sample, and each output is float32(double(x) * gain).
      The reference below is written from that description, not from the C++,
      and is compared bit for bit, at two block sizes, so a block boundary
      falling anywhere cannot change a sample;
  (b) no click: on full-scale DC, no step between consecutive outputs exceeds
      what the ramp in progress allows (1/N of the level, plus one float32
      ulp, plus whatever the stage's own output moved by);
  (c) a script that only ever asks for unity leaves the output byte for byte
      what it is with no script, and so does the tail of a run once every
      ramp has come back to rest at unity: at rest the block is not there.

The reference takes the stage's own output (a run with no script) as its
input, so the stage's filters need not be modelled: with the F64 format the
runner's only rounding is the float32 at the buffer boundary, which the stage
and the monitor block share, and a no-script run carries exactly the floats
the monitor block was handed.

Offline: no ALSA device is opened and no service is touched. Needs the runner
(`usb16x16-dsp-offline`, built from dsp-core) and, unless --artifact is given,
node to compile the transparent verification preset.

Exit status 0 when every check passes, 1 otherwise.
"""

import argparse
import array
import math
import subprocess
import sys
import tempfile
from pathlib import Path

CHANNELS = 16
HERE = Path(__file__).resolve().parent


def float32(values):
    """Each double rounded to the nearest float32, back as doubles."""
    return array.array("d", array.array("f", values))


def ulp32(value):
    """One float32 unit in the last place at |value| (the spacing above it)."""
    value = abs(value)
    if value == 0.0:
        return 2.0 ** -149
    exponent = math.frexp(value)[1]          # value = m * 2**exponent, 0.5 <= m < 1
    return 2.0 ** (exponent - 24)


def compile_transparent(work, rate):
    preset = work / "transparent.json"
    artifact = work / "transparent.dsp"
    with open(preset, "w") as out:
        subprocess.run(["node", str(HERE / "verify-presets.mjs"), "transparent"],
                       stdout=out, check=True)
    subprocess.run([str(HERE / "usb16x16-dsp-compile"), str(preset),
                    "-o", str(work / "transparent.yml"), "--bridge", str(artifact),
                    "--rate", str(rate)],
                   check=True, stdout=subprocess.DEVNULL)
    return artifact


def write_f64(path, samples):
    data = array.array("d", samples)
    if sys.byteorder != "little":
        data.byteswap()
    Path(path).write_bytes(data.tobytes())


def read_f64(path):
    data = array.array("d")
    data.frombytes(Path(path).read_bytes())
    if sys.byteorder != "little":
        data.byteswap()
    return data


def run_runner(runner, artifact, rate, source, dest, block, script=None):
    command = [runner, str(artifact), "--in", str(source), "--out", str(dest),
               "--format", "f64le", "--rate", str(rate), "--block", str(block)]
    if script is not None:
        command += ["--monitor-script", str(script)]
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(command)} exited {done.returncode}: {done.stderr.strip()}")
    return Path(dest).read_bytes()


# ------------------------------------------------------------------ script

def gains_event(frame, ramp, gains):
    return {"frame": frame, "silence": False, "ramp": ramp, "gains": list(gains)}


def silence_event(frame, ramp):
    return {"frame": frame, "silence": True, "ramp": ramp}


def write_script(path, events, comment):
    lines = [f"# {comment}"]
    for event in events:
        if event["silence"]:
            lines.append(f"{event['frame']} silence ramp={event['ramp']}")
        else:
            # repr round-trips a double exactly, so the runner parses the same value.
            gains = ",".join(repr(float(g)) for g in event["gains"])
            lines.append(f"{event['frame']} ramp={event['ramp']} gains={gains}")
    Path(path).write_text("\n".join(lines) + "\n")


def main_script():
    """The events the sine and DC runs share.

    A start from silence, a ramp down to zero over 480, back up over 1920, a
    retarget in the middle of that ramp to a different gain on every channel,
    a step, a return to unity over 1920 (so the tail is at rest), and a
    re-prime from silence at the end.
    """
    every = lambda g: [g] * CHANNELS
    varied = [(c + 1) / 17.0 for c in range(CHANNELS)]
    stepped = [0.0 if c % 3 == 0 else 1.0 - c / 40.0 for c in range(CHANNELS)]
    return [
        silence_event(0, 480),
        gains_event(2000, 480, every(0.0)),
        gains_event(3000, 1920, every(1.0)),
        gains_event(3960, 480, varied),           # 960 frames into the 1920 ramp
        gains_event(5000, 1, stepped),
        gains_event(6000, 1920, every(1.0)),      # at rest at unity from frame 7919
        gains_event(9000, 960, every(1.0)),       # unity onto unity: nothing moves
        silence_event(10000, 960),                # a re-prime
    ]


# --------------------------------------------------------------- reference

def reference(base, frames, events):
    """MonitorGains as its header documents it, from the stage's output."""
    gain = [1.0] * CHANNELS
    target = [1.0] * CHANNELS
    step = [0.0] * CHANNELS
    remaining = [0] * CHANNELS
    # The ramp length in force on each sample, for the click bound; 0 at rest.
    ramp_of = [0] * frames
    products = [0.0] * (frames * CHANNELS)
    pending = list(events)
    current_ramp = 0
    for n in range(frames):
        while pending and pending[0]["frame"] == n:
            event = pending.pop(0)
            length = max(event["ramp"], 1)
            if event["silence"]:
                for c in range(CHANNELS):
                    gain[c] = 0.0
                    if target[c] == 0.0:
                        remaining[c] = 0
                    else:
                        step[c] = target[c] / length
                        remaining[c] = length
            else:
                for c in range(CHANNELS):
                    t = event["gains"][c]
                    if t == target[c]:
                        continue
                    target[c] = t
                    if gain[c] == t:
                        remaining[c] = 0
                    else:
                        step[c] = (t - gain[c]) / length
                        remaining[c] = length
            current_ramp = length
        moving = False
        for c in range(CHANNELS):
            if remaining[c] > 0:
                gain[c] = gain[c] + step[c]
                remaining[c] -= 1
                if remaining[c] == 0:
                    gain[c] = target[c]
                moving = True
            products[n * CHANNELS + c] = base[n * CHANNELS + c] * gain[c]
        ramp_of[n] = current_ramp if moving else 0
    return float32(products), ramp_of


# ------------------------------------------------------------------ checks

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--runner", required=True, help="the usb16x16-dsp-offline binary")
    parser.add_argument("--artifact", help="a bridge artifact (default: the transparent "
                        "verification preset, compiled here)")
    parser.add_argument("--rate", type=int, default=48000)
    parser.add_argument("--frames", type=int, default=12000)
    parser.add_argument("--work", help="keep the files here (default: a temporary directory)")
    arguments = parser.parse_args()

    with tempfile.TemporaryDirectory() as scratch:
        work = Path(arguments.work) if arguments.work else Path(scratch)
        work.mkdir(parents=True, exist_ok=True)
        artifact = Path(arguments.artifact) if arguments.artifact else compile_transparent(work, arguments.rate)
        return run_checks(arguments.runner, artifact, arguments.rate, arguments.frames, work)


def run_checks(runner, artifact, rate, frames, work):
    failures = 0

    def report(ok, name, detail):
        nonlocal failures
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
        if not ok:
            failures += 1

    events = main_script()
    if events[-1]["frame"] >= frames:
        raise SystemExit("--frames is shorter than the script")
    script = work / "monitor.script"
    write_script(script, events, "verify-monitor.py: the main script")

    # A 997 Hz sine at -6 dBFS, a different phase on every channel.
    sine = [0.5 * math.sin(2 * math.pi * 997.0 * n / rate + c * 0.37)
            for n in range(frames) for c in range(CHANNELS)]
    sine_in = work / "sine-in.f64"
    write_f64(sine_in, sine)
    base_bytes = run_runner(runner, artifact, rate, sine_in, work / "sine-base.f64", 48)
    base = read_f64(work / "sine-base.f64")
    expected, _ = reference(base, frames, events)
    expected_bytes = expected.tobytes() if sys.byteorder == "little" else None

    # (a) bit for bit, at the default block and an awkward one.
    for block in (48, 7):
        got = run_runner(runner, artifact, rate, sine_in, work / f"sine-monitor-{block}.f64", block, script)
        got_values = read_f64(work / f"sine-monitor-{block}.f64")
        mismatches = [i for i in range(min(len(got_values), len(expected)))
                      if got_values[i] != expected[i] or
                      math.copysign(1.0, got_values[i]) != math.copysign(1.0, expected[i])]
        same = len(got_values) == len(expected) and not mismatches
        if expected_bytes is not None:
            same = same and got == expected_bytes
        detail = (f"{len(expected)} samples identical to the reference at --block {block}" if same else
                  f"{len(mismatches)} of {len(expected)} samples differ at --block {block}, first at frame "
                  f"{mismatches[0] // CHANNELS if mismatches else '?'}")
        report(same, f"reference (sine, block {block})", detail)

    # (c, tail) once the return to unity has finished, the tail is the stage's own output until the re-prime.
    rest_from, rest_to = 6000 + 1920 - 1 + 1, 10000
    got_values = read_f64(work / "sine-monitor-48.f64")
    tail_same = all(got_values[i] == base[i] and math.copysign(1.0, got_values[i]) == math.copysign(1.0, base[i])
                    for i in range(rest_from * CHANNELS, rest_to * CHANNELS))
    report(tail_same, "at rest after a ramp",
           f"frames {rest_from}-{rest_to - 1} are the no-script output byte for byte"
           if tail_same else f"frames {rest_from}-{rest_to - 1} differ from the no-script output")

    # (b) the click bound on full-scale DC.
    dc_in = work / "dc-in.f64"
    write_f64(dc_in, [1.0] * (frames * CHANNELS))
    run_runner(runner, artifact, rate, dc_in, work / "dc-base.f64", 48)
    dc_base = read_f64(work / "dc-base.f64")
    run_runner(runner, artifact, rate, dc_in, work / "dc-monitor.f64", 48, script)
    dc_out = read_f64(work / "dc-monitor.f64")
    dc_expected, ramp_of = reference(dc_base, frames, events)
    peak = max(abs(v) for v in dc_base)
    # A start from silence drops the gain to zero by design (a start or a
    # re-prime follows a gap in the audio); its first sample is not a ramp step.
    jumps = {e["frame"] for e in events if e["silence"]}
    # The worst step as a share of what it was allowed: 1.0 is on the bound.
    worst_share, worst_at, worst_step, largest_step = 0.0, (0, 0), 0.0, 0.0
    for n in range(1, frames):
        if n in jumps:
            continue
        allowed_gain = 1.0 / ramp_of[n] if ramp_of[n] else 0.0
        for c in range(CHANNELS):
            i = n * CHANNELS + c
            moved = abs(dc_out[i] - dc_out[i - CHANNELS])
            stage_moved = abs(dc_base[i] - dc_base[i - CHANNELS])
            bound = stage_moved + peak * allowed_gain + ulp32(max(abs(dc_out[i]), abs(dc_out[i - CHANNELS])))
            if ramp_of[n] > 1:
                largest_step = max(largest_step, moved)
            if moved / bound > worst_share:
                worst_share, worst_at, worst_step = moved / bound, (n, c + 1), moved
    clicks_ok = worst_share <= 1.0
    report(clicks_ok, "no click (full-scale DC)",
           f"largest step in a ramp {largest_step:.4e} (1/480 is {1 / 480:.4e}; the ramp=1 step is "
           f"allowed a whole step); worst share of its bound "
           f"{worst_share:.6f} at frame {worst_at[0]} output {worst_at[1]}; the starts from silence "
           f"at frames {sorted(jumps)} are excluded"
           if clicks_ok else
           f"frame {worst_at[0]} output {worst_at[1]} stepped {worst_step:.4e}, "
           f"{worst_share:.6f} of its bound")
    dc_same = dc_out.tobytes() == dc_expected.tobytes()
    report(dc_same, "reference (DC)", "identical to the reference" if dc_same else "differs from the reference")

    # (c) a script that only asks for unity is not there.
    unity_script = work / "unity.script"
    write_script(unity_script, [gains_event(0, 480, [1.0] * CHANNELS),
                                gains_event(1000, 1, [1.0] * CHANNELS),
                                gains_event(1000, 1920, [1.0] * CHANNELS),
                                gains_event(5000, 0, [1.0] * CHANNELS)],
                 "verify-monitor.py: unity only")
    unity = run_runner(runner, artifact, rate, sine_in, work / "sine-unity.f64", 48, unity_script)
    report(unity == base_bytes, "unity script is byte-identical",
           f"{len(unity)} bytes, the same as with no script" if unity == base_bytes else
           "the output differs from the run with no script")

    print(f"verify-monitor: {'all passed' if failures == 0 else f'{failures} FAILED'} "
          f"(artifact {artifact.name}, {frames} frames at {rate} Hz)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
