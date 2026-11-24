#!/usr/bin/env python3
"""Check two speaker sets sharing a subwoofer (preset model v3) file to file.

`verify-sets` is the shipped 5.1 layout on outputs 1-6 with bass management
on (crossovers at 80 Hz, the LFE sub on output 4), a stereo nearfield pair on
outputs 7-8 that shares the main sub (subShare main), and headphones on 15-16;
`verify-sets-single` is the same preset without the nearfield, and
`verify-sets-none` the nearfield with no subwoofer (subShare none). Each set
reads its own view of the inputs; a set that is not playing has the reserved
fold `off` engaged (the owner's monitor_ctl does it; here the runner's script
does what the owner would) so it feeds nothing to the shared sub. Through
`usb16x16-dsp-offline`, on a deterministic multi-tone on all 16 inputs:

  (a) topology: the sets, the sub listed for both speaker sets, every speaker
      set's folds ending in `off`, the single-set preset with no `off`;
  (b) mains playing, nearfield `off` (its outputs at gain 0, as the owner
      publishes for a set not active): the sub, the mains and the headphones
      are byte for byte the single-set preset's. Exact, not a tolerance: the
      silent view's branches add exact zeros to the sub's sum;
  (c) switched, nearfield playing and mains `off`: the sub is byte for byte
      the single-set preset's sub driven by the nearfield's inputs alone (L, R
      and the LFE: the bass of what its speakers play, through the same
      crossovers and sends), the mains silent, the headphones untouched;
  (d) both playing (All sets): the sub is the sum of (b) and (c). The runner
      sums in double and rounds once to float32; the two references are each
      float32 already, so per sample the allowance is half a float32 ulp of
      the output plus half an ulp of each reference term (verify-fold.py's
      bound, two terms);
  (e) the switch itself, as the owner makes it: first step every output at
      min(old, new) over 10 ms with mains -> off and nearfield -> full in the
      same block, then the new gains 10 ms after. Before the switch the sub is
      (b)'s exactly; from 200 ms after it, (c)'s within (d)'s bound (the
      mains' crossover tails have decayed by then); in between, the largest
      sample-to-sample step of the sub is printed against the larger of the
      two references' largest steps over the same frames;
  (f) no subwoofer: compiled with subShare none, the nearfield's outputs are
      its inputs through its own EQ only, modelled here from the artifact's
      coefficients (no crossover high-pass: a 30 Hz tone passes at its EQ
      gain, against the shared preset's high-passed one), and the sub never
      carries the nearfield's content;
  (g) the headphones are byte for byte the single-set preset's in every run;
  (h) byte identity on one set: `verify-sets-single` with the section gives
      the bytes it gives with --no-monitor.

--bench N prints the stage's cost for the two-set preset (nearfield `off`,
as it runs when the mains play) against the single-set preset, same runner.

Offline: no ALSA device is opened and no service is touched. Needs the runner
(built from dsp-core) and node. Exit status 0 when every check passes.
"""

import argparse
import importlib.util
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

CHANNELS = 16
HERE = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("verify_monitor", HERE / "verify-monitor.py")
vm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vm)
write_f64, read_f64, float32, ulp32 = vm.write_f64, vm.read_f64, vm.float32, vm.ulp32

MAINS, NEAR, PHONES, SUB = [0, 1, 2, 4, 5], [6, 7], [14, 15], 3
NEAR_INPUTS = [0, 1, 3]                       # L, R and the LFE


def compile_preset(work, name, rate, monitor=True):
    preset = work / f"{name}.json"
    artifact = work / f"{name}{'' if monitor else '-nomonitor'}.dsp"
    with open(preset, "w") as out:
        subprocess.run(["node", str(HERE / "verify-presets.mjs"), name], stdout=out, check=True)
    command = [str(HERE / "usb16x16-dsp-compile"), str(preset), "-o", str(work / f"{name}.yml"),
               "--bridge", str(artifact), "--rate", str(rate)]
    if not monitor:
        command.append("--no-monitor")
    done = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if done.returncode not in (0, 1):            # 1: an output can clip, still written
        raise RuntimeError(done.stderr)
    return artifact


def run(runner, artifact, rate, source, dest, block=48, script=None):
    command = [runner, str(artifact), "--in", str(source), "--out", str(dest),
               "--format", "f64le", "--rate", str(rate), "--block", str(block)]
    if script is not None:
        command += ["--monitor-script", str(script)]
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(command)} exited {done.returncode}: {done.stderr.strip()}")
    return read_f64(dest)


def read_section(text):
    """Sets, outs and fold names from the monitor section (from its format)."""
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    if "monitor 1" not in lines:
        return [], {}, {}
    at = lines.index("monitor 1") + 1

    def take():
        nonlocal at
        at += 1
        return lines[at - 1].split()

    sets = [tuple(take()[1:]) for _ in range(int(take()[1]))]
    outs = {}
    for _ in range(int(take()[1])):
        words = take()
        outs[int(words[1])] = (words[2], [int(w) for w in words[3:]])
    words = take()
    while words[0] == "label":
        words = take()
    for _ in range(int(words[1])):
        take()
    folds = {}
    for _ in range(int(take()[1])):
        _, set_index, name, rows = take()
        folds.setdefault(int(set_index), []).append(name)
        for _ in range(int(rows)):
            take()
    return sets, outs, folds


def output_sections(text, output):
    """(delay, gain, [biquads]) of one output from the artifact's output section."""
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    at = next(i for i, line in enumerate(lines) if line.startswith("output "))
    at += 1
    for _ in range(CHANNELS):
        index, delay, gain, count = lines[at].split()
        sections = [tuple(float(v) for v in lines[at + 1 + k].split()) for k in range(int(count))]
        if int(index) == output:
            return int(delay), float(gain), sections
        at += 1 + int(count)
    raise ValueError(f"no output {output}")


def path_gain(text, output, source):
    """The expand gain times the assign gain from input `source` to `output`
    through the one branch that carries it (a speaker's main branch)."""
    lines = [line.strip() for line in text.split("\n") if line.strip()]

    def rows(keyword):
        at = next(i for i, line in enumerate(lines) if line.startswith(keyword + " "))
        return [tuple(lines[at + 1 + k].split()) for k in range(int(lines[at].split()[1]))]

    expand, assign = rows("expand"), rows("assign")
    (channel, a), = [(int(src), float(g)) for dest, src, g in assign if int(dest) == output]
    (e,) = [float(g) for dest, src, g in expand if int(dest) == channel and int(src) == source]
    return e, a


def biquads(signal, sections):
    """Direct form I in double, the same difference equation as DspStage."""
    out = list(signal)
    for b0, b1, b2, a1, a2 in sections:
        x1 = x2 = y1 = y2 = 0.0
        filtered = []
        for x in out:
            y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, x, y1, y
            filtered.append(y)
        out = filtered
    return out


def gains_line(frame, ramp, gains):
    return f"{frame} ramp={ramp} gains={','.join(repr(float(g)) for g in gains)}"


def every(mains, near, sub, phones=1.0):
    gains = [1.0] * CHANNELS
    for o in MAINS:
        gains[o] = mains
    for o in NEAR:
        gains[o] = near
    gains[SUB] = sub
    for o in PHONES:
        gains[o] = phones
    return gains


def column(data, output):
    return data[output::CHANNELS]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--runner", required=True, help="the usb16x16-dsp-offline binary")
    parser.add_argument("--rate", type=int, default=48000)
    parser.add_argument("--bench", type=int, default=0, help="also time N process() calls per preset")
    parser.add_argument("--work", help="keep the files here (default: a temporary directory)")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(arguments.work) if arguments.work else Path(scratch)
        work.mkdir(parents=True, exist_ok=True)
        return run_checks(arguments.runner, arguments.rate, work, arguments.bench)


def run_checks(runner, rate, work, bench):
    failures = 0

    def report(ok, name, detail):
        nonlocal failures
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
        if not ok:
            failures += 1

    ramp = max(rate // 100, 1)
    two = compile_preset(work, "sets", rate)
    single = compile_preset(work, "sets-single", rate)
    single_plain = compile_preset(work, "sets-single", rate, monitor=False)
    none = compile_preset(work, "sets-none", rate)

    # (a) topology.
    sets, outs, folds = read_section(two.read_text())
    _, _, single_folds = read_section(single.read_text())
    ok = (sets == [("speakers", "speakers"), ("speakers-2", "speakers"), ("phones", "headphones")]
          and outs[SUB] == ("sub", [0, 1]) and all(outs[o] == ("speaker", [1]) for o in NEAR)
          and folds.get(0, [])[-1:] == ["off"] and folds.get(1, [])[-1:] == ["off"]
          and not any("off" in names for names in single_folds.values()))
    report(ok, "topology", f"sets {[s[0] for s in sets]}; output {SUB + 1} is a sub of sets {outs[SUB][1]}; folds "
           f"{folds}; the single-set preset's {single_folds} (no off)")

    # The drive: a different multi-tone on every input, silent for the first
    # 2 * ramp frames so every fold is settled before anything sounds.
    frames = int(rate * 0.8)
    quiet = 2 * ramp
    tones = [(23.0 + 7.0 * c, 61.0 + 13.0 * c, 997.0 + 101.0 * c) for c in range(CHANNELS)]

    def drive(keep=range(CHANNELS)):
        keep = set(keep)
        return [0.0 if n < quiet or c not in keep else
                0.12 * math.sin(2 * math.pi * tones[c][0] * n / rate + c) +
                0.08 * math.sin(2 * math.pi * tones[c][1] * n / rate + 2 * c) +
                0.05 * math.sin(2 * math.pi * tones[c][2] * n / rate + 3 * c)
                for n in range(frames) for c in range(CHANNELS)]

    full_in, near_in = work / "drive.f64", work / "drive-near.f64"
    write_f64(full_in, drive())
    write_f64(near_in, drive(NEAR_INPUTS))
    ref = run(runner, single, rate, full_in, work / "single.f64")
    ref_near = run(runner, single, rate, near_in, work / "single-near.f64")
    phones_ref = [column(ref, o) for o in PHONES]

    def script(name, lines):
        path = work / f"{name}.script"
        path.write_text(f"# verify-sets.py: {name}\n" + "\n".join(lines) + "\n")
        return path

    def phones_same(got):
        return all(list(column(got, o)) == list(phones_ref[k]) for k, o in enumerate(PHONES))

    # (b) mains playing, nearfield off.
    mains_only = run(runner, two, rate, full_in, work / "mains.f64", script=script("mains", [
        "0 fold speakers-2 off", gains_line(0, 1, every(1.0, 0.0, 1.0))]))
    same_sub = list(column(mains_only, SUB)) == list(column(ref, SUB))
    same_mains = all(list(column(mains_only, o)) == list(column(ref, o)) for o in MAINS)
    silent = all(v == 0.0 for o in NEAR for v in column(mains_only, o))
    report(same_sub and same_mains and silent and phones_same(mains_only), "mains playing, nearfield off",
           f"sub, mains and headphones byte for byte the single-set preset's over {frames} frames; nearfield silent"
           if same_sub and same_mains and silent else
           f"sub same {same_sub}, mains same {same_mains}, nearfield silent {silent}")

    # (c) nearfield playing, mains off.
    near_only = run(runner, two, rate, full_in, work / "near.f64", script=script("near", [
        "0 fold speakers off", "0 fold speakers-2 full", gains_line(0, 1, every(0.0, 1.0, 1.0))]))
    same_sub = list(column(near_only, SUB)) == list(column(ref_near, SUB))
    nonzero = max(abs(v) for v in column(near_only, SUB))
    mains_silent = all(v == 0.0 for o in MAINS for v in column(near_only, o))
    report(same_sub and nonzero > 1e-3 and mains_silent and phones_same(near_only), "nearfield playing, mains off",
           f"the sub is byte for byte the single-set preset's sub on inputs {[i + 1 for i in NEAR_INPUTS]} alone "
           f"(peak {nonzero:.4f}); mains silent; headphones untouched" if same_sub else "the sub differs")

    # (d) both playing.
    both = run(runner, two, rate, full_in, work / "both.f64")

    def within(got, a, b, start=0):
        worst, at = 0.0, None
        for n in range(start, frames):
            bound = 0.5 * ulp32(got[n]) + 0.5 * ulp32(a[n]) + 0.5 * ulp32(b[n]) + 1e-30
            share = abs(got[n] - (a[n] + b[n])) / bound
            if share > worst:
                worst, at = share, n
        return worst, at

    worst, at = within(column(both, SUB), column(ref, SUB), column(ref_near, SUB))
    report(worst <= 1.0 and phones_same(both), "both playing (All sets)",
           f"the sub is the sum of the two within half an ulp of each term and of the output; worst {worst:.4f} "
           f"of the bound at frame {at}")

    # (e) the switch, mains -> nearfield, as the owner publishes it.
    at_switch = int(rate * 0.3)
    second = at_switch + ramp + ramp      # the first step's 10 ms, then 10 ms after it was taken
    switched = run(runner, two, rate, full_in, work / "switch.f64", script=script("switch", [
        "0 fold speakers-2 off", gains_line(0, 1, every(1.0, 0.0, 1.0)),
        f"{at_switch} fold speakers off", f"{at_switch} fold speakers-2 full",
        gains_line(at_switch, ramp, every(0.0, 0.0, 1.0)),
        gains_line(second, ramp, every(0.0, 1.0, 1.0))]))
    sub = column(switched, SUB)
    before = list(sub[:at_switch]) == list(column(ref, SUB)[:at_switch])
    settle = at_switch + int(rate * 0.2)
    after, after_at = within(sub, [0.0] * frames, column(ref_near, SUB), settle)

    def largest_step(values, lo, hi):
        return max(abs(values[n] - values[n - 1]) for n in range(lo, hi))

    window = (at_switch, at_switch + 4 * ramp)
    step = largest_step(sub, *window)
    reference_step = max(largest_step(column(ref, SUB), *window), largest_step(column(ref_near, SUB), *window))
    report(before and after <= 1.0 and step <= reference_step and phones_same(switched), "the switch",
           f"before it the sub is (b) byte for byte; from 200 ms after it (c) within the bound (worst {after:.4f}); "
           f"over the 40 ms from the switch its largest step is {step:.3e}, the references' {reference_step:.3e}")

    # (f) no subwoofer: full range, nothing on the sub.
    none_text = none.read_text()
    near_none = run(runner, none, rate, full_in, work / "none.f64", script=script("none", [
        "0 fold speakers off", "0 fold speakers-2 full", gains_line(0, 1, every(0.0, 1.0, 1.0))]))
    sub_silent = all(v == 0.0 for v in column(near_none, SUB))
    model_ok, worst = True, 0.0
    source = float32(drive())            # the runner hands the stage float32 samples
    for o, i in zip(NEAR, (0, 1)):
        delay, g, sections = output_sections(none_text, o)
        e, a = path_gain(none_text, o, i)
        x = [a * (e * source[n * CHANNELS + i]) for n in range(frames)]   # the headroom, a unity assign row
        y = biquads(x, sections)
        y = [0.0] * delay + [g * v for v in y[:frames - delay]]
        got = column(near_none, o)
        for n in range(frames):
            share = abs(got[n] - y[n]) / (0.5 * ulp32(got[n]) + 1e-12)
            worst = max(worst, share)
            if share > 1.0:
                model_ok = False

    def tone_level(artifact, name):
        n_frames = int(rate * 0.5)
        x = [0.0] * (n_frames * CHANNELS)
        for n in range(n_frames):
            x[n * CHANNELS] = 0.25 * math.sin(2 * math.pi * 30.0 * n / rate)
        path = work / f"tone-{name}.f64"
        write_f64(path, x)
        got = run(runner, artifact, rate, path, work / f"tone-{name}-out.f64", script=script(f"tone-{name}", [
            "0 fold speakers off", "0 fold speakers-2 full", gains_line(0, 1, every(0.0, 1.0, 1.0))]))
        tail = column(got, NEAR[0])[n_frames // 2:]
        return 20 * math.log10(max(abs(v) for v in tail) / 0.25) - headroom

    headroom = json.loads((work / "sets-none.json").read_text())["headroomDb"]
    shared_db, none_db = tone_level(two, "shared"), tone_level(none, "none")
    report(sub_silent and model_ok and none_db > -0.5 and shared_db < -10.0, "no subwoofer: full range",
           f"nearfield outputs equal its EQ alone modelled from the artifact (worst {worst:.4f} of half an ulp + 1e-12); "
           f"30 Hz on L reaches output {NEAR[0] + 1} at {none_db:+.2f} dB after the {headroom} dB headroom (sharing the sub: "
           f"{shared_db:+.2f} dB, high-passed); "
           f"the sub is exactly silent")

    # (h) byte identity on one set.
    plain = run(runner, single_plain, rate, full_in, work / "single-plain.f64")
    report(list(plain) == list(ref), "one set: the section changes nothing",
           f"{frames * CHANNELS} samples identical with and without the monitor section")

    if bench:
        results = {}
        for name, artifact, extra in (("single", single, []), ("two sets, nearfield off", two, ["--bench-fold", "speakers-2", "off"]),
                                      ("two sets, both playing", two, [])):
            done = subprocess.run([runner, str(artifact), "--bench", str(bench), "--block", "32", "--rate", str(rate),
                                   "--bench-monitor", "1", *extra], capture_output=True, text=True, check=True)
            results[name] = json.loads(done.stdout.strip().splitlines()[-1])
        base = results["single"]["median_us"]
        for name, r in results.items():
            print(f"BENCH {name}: median {r['median_us']:.2f} us, p99 {r['p99_us']:.2f} us, max {r['max_us']:.2f} us "
                  f"per 32-frame block ({100 * r['duty_median']:.1f}% of the block), {r['median_us'] / base:.2f}x single")

    print(f"verify-sets: {'all passed' if failures == 0 else f'{failures} FAILED'} ({rate} Hz)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
