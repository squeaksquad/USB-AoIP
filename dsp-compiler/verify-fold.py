#!/usr/bin/env python3
"""Check the bridge's fold-downs (the artifact's monitor section) file to file.

A fold-down is a matrix on the stage's inputs, before bass management and
before each speaker's EQ. What has to hold, and what this measures through
`usb16x16-dsp-offline`:

  (a) the fold table: the rows the compiler wrote for the 7.2.4 speakers equal
      a table built here from the written rule (5.1, stereo, mono with
      a = sqrt(1/2), h = 1/2, only the inputs the set uses), exactly;
  (b) linearity through the whole stage. `verify-fold` is the shipped 7.2.4
      layout with bass management on, a PEQ on every speaker and a delay on
      the centre, plus a headphones pair. For each input s, one impulse per
      segment while a script moves the speakers full -> 5.1 -> stereo ->
      mono -> full. The impulses fall only where no crossfade is running, so
      the stage is linear in them and the output must be
          speaker outputs:  sum over impulses k, dests d of M_k[d][s] * R_d(t - t_k)
          headphones:       sum over k of R_s(t - t_k)          (never folded)
      where R_d is the runner's own response to an impulse on input d with
      every set on full. Exact arithmetic would make the two equal; the
      runner rounds its output to float32 and R_d is float32 too, so the
      check allows, per sample, half a float32 ulp of the output plus the sum
      of |gain| * half an ulp of each R term, plus 1e-12 absolute for the
      double-precision reassociation inside the filters (the engine filters
      g*x, the model scales the filtered x by g). The worst measured share of
      that bound is printed;
  (c) the crossfade: `verify-fold-flat` is the same speakers with nothing in
      the way, so a speaker output is its input view times one. On DC with a
      different level per input, a script runs full -> 5.1 -> stereo -> mono
      -> full plus a request made during a crossfade. The output must equal,
      bit for bit, the arithmetic DspStage's header documents (accumulated
      a, snapped to 1 on the Nth sample; a deferred request starts at the
      first block top after the crossfade ends), modelled here with the
      runner's own block splits, at two block sizes; no step may exceed
      |B - A| / N plus one float32 ulp; and the subs (the LFE, which every
      fold passes) must not move at all;
  (d) byte identity: with every set on full the artifact with the section
      gives the same bytes as the same preset compiled with --no-monitor,
      with no script and with a script that only ever asks for full.

Offline: no ALSA device is opened and no service is touched. Needs the runner
(built from dsp-core) and node to compile the presets. Exit status 0 when
every check passes, 1 otherwise.
"""

import argparse
import importlib.util
import math
import subprocess
import sys
import tempfile
from pathlib import Path

CHANNELS = 16
HERE = Path(__file__).resolve().parent

# The shared file helpers live in verify-monitor.py.
_spec = importlib.util.spec_from_file_location("verify_monitor", HERE / "verify-monitor.py")
vm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vm)
write_f64, read_f64, float32, ulp32 = vm.write_f64, vm.read_f64, vm.float32, vm.ulp32


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


def run(runner, artifact, rate, source, dest, block, script=None):
    command = [runner, str(artifact), "--in", str(source), "--out", str(dest),
               "--format", "f64le", "--rate", str(rate), "--block", str(block)]
    if script is not None:
        command += ["--monitor-script", str(script)]
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(command)} exited {done.returncode}: {done.stderr.strip()}")
    return Path(dest).read_bytes()


# ------------------------------------------------------------ the artifact

def read_section(text):
    """Sets, outputs and folds from the artifact's monitor section (a reader
    of the format, written from its description, not from the JS or C++)."""
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    at = lines.index("monitor 1") + 1
    sets, outs, folds = [], {}, {}

    def take():
        nonlocal at
        at += 1
        return lines[at - 1].split()

    for _ in range(int(take()[1])):
        _, ident, kind = take()
        sets.append((ident, kind))
    for _ in range(int(take()[1])):
        words = take()
        outs[int(words[1])] = (words[2], [int(w) for w in words[3:]])
    words = take()
    while words[0] == "label":
        words = take()
    expand_sets = [None if take()[0] == "-" else 0 for _ in range(int(words[1]))]
    for _ in range(int(take()[1])):
        _, set_index, name, rows = take()
        folds[(int(set_index), name)] = [(int(d), int(s), float(g)) for d, s, g in (take() for _ in range(int(rows)))]
    return sets, outs, expand_sets, folds


def fold_table(used, lfe=3):
    """The fold rule, written out: {name: {dest: {src: gain}}}."""
    a, h = math.sqrt(0.5), 0.5
    L, R, C, Ls, Rs, Lrs, Rrs, Ltf, Rtf, Ltr, Rtr, Lw, Rw, Ltm, Rtm = (0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)

    def row(*terms):
        return {s: g for s, g in terms if s in used}

    five = {L: row((L, 1.0), (Lw, a), (Ltf, a), (Ltm, h)),
            R: row((R, 1.0), (Rw, a), (Rtf, a), (Rtm, h)),
            C: row((C, 1.0)),
            Ls: row((Ls, 1.0), (Lrs, a), (Ltr, a), (Ltm, h)),
            Rs: row((Rs, 1.0), (Rrs, a), (Rtr, a), (Rtm, h))}

    def add(*weighted):
        out = {}
        for weight, terms in weighted:
            for s, g in terms.items():
                out[s] = out.get(s, 0.0) + weight * g
        return out

    stereo = {L: add((1.0, five[L]), (a, five[C]), (a, five[Ls])),
              R: add((1.0, five[R]), (a, five[C]), (a, five[Rs]))}
    mono_row = add((0.5, stereo[L]), (0.5, stereo[R]))
    mono = {L: mono_row, R: dict(mono_row)}
    table = {}
    others = any(s not in (L, R, 3, lfe) for s in used)
    if all(s in used for s in (L, R, C, Ls, Rs)) and any(s > Rs for s in used):
        table["5.1"] = five
    if L in used and R in used and others:
        table["stereo"] = stereo
    if L in used and R in used:
        table["mono"] = mono
    for fold in table.values():
        fold[lfe] = {lfe: 1.0}
        for dest in [d for d, terms in fold.items() if not terms]:
            del fold[dest]
    return table


def matrix_of(rows):
    """{(dest, src): gain} from a fold's rows; None for full (the identity)."""
    return None if rows is None else {(d, s): g for d, s, g in rows}


def gain(matrix, dest, source):
    if matrix is None:
        return 1.0 if dest == source else 0.0
    return matrix.get((dest, source), 0.0)


# ------------------------------------------------------------------ checks

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--runner", required=True, help="the usb16x16-dsp-offline binary")
    parser.add_argument("--rate", type=int, default=48000)
    parser.add_argument("--work", help="keep the files here (default: a temporary directory)")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(arguments.work) if arguments.work else Path(scratch)
        work.mkdir(parents=True, exist_ok=True)
        return run_checks(arguments.runner, arguments.rate, work)


def run_checks(runner, rate, work):
    failures = 0

    def report(ok, name, detail):
        nonlocal failures
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
        if not ok:
            failures += 1

    ramp = max(rate // 100, 1)
    fold_art = compile_preset(work, "fold", rate)
    plain_art = compile_preset(work, "fold", rate, monitor=False)
    sets, outs, expand_sets, folds = read_section(fold_art.read_text())

    # (a) the fold table.
    speakers = [o for o, (role, member) in outs.items() if role == "speaker" and member == [0]]
    sources = [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11]           # 7.2.4: speaker o plays input o
    table = fold_table(set(sources))
    written = {name: matrix_of(rows) for (set_index, name), rows in folds.items() if set_index == 0}
    expected = {name: {(d, s): g for d, terms in fold.items() for s, g in terms.items()} for name, fold in table.items()}
    same_table = written == expected and sets == [("speakers", "speakers"), ("phones", "headphones")]
    report(same_table, "fold table", f"the artifact's {', '.join(written)} rows equal the rule exactly "
           f"({sum(len(m) for m in written.values())} gains)" if same_table else
           f"artifact {sorted(written)} differs from the rule {sorted(expected)}")
    phones = [o for o, (role, member) in outs.items() if member == [1]]
    report(speakers == [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11] and phones == [13, 14]
           and expand_sets.count(None) == 2, "topology",
           f"speakers {speakers}, headphones {phones}, {expand_sets.count(None)} of {len(expand_sets)} "
           "expand rows read the inputs unfolded")

    # (b) linearity through bass management, EQ and delay.
    frames = 5000
    segments = [("full", 200), ("5.1", 1200), ("stereo", 2200), ("mono", 3200), ("full", 4200)]
    switches = [(600, "5.1"), (1600, "stereo"), (2600, "mono"), (3600, "full")]
    assert all(at + ramp < impulse for (at, _), (_, impulse) in zip(switches, segments[1:])), "crossfade overlaps an impulse"
    script = work / "linear.script"
    script.write_text("# verify-fold.py: full -> 5.1 -> stereo -> mono -> full\n"
                      + "".join(f"{at} fold speakers {name}\n" for at, name in switches))
    amplitude = 0.5
    responses = []
    for d in range(CHANNELS):
        source = work / f"impulse-{d}.f64"
        write_f64(source, [amplitude if (n == 0 and c == d) else 0.0 for n in range(frames) for c in range(CHANNELS)])
        run(runner, fold_art, rate, source, work / f"full-{d}.f64", 48)
        responses.append(read_f64(work / f"full-{d}.f64"))
    # Each response by output column, with the slack each of its samples brings.
    columns = [[list(r[o::CHANNELS]) for o in range(CHANNELS)] for r in responses]
    halves = [[[0.5 * ulp32(v) + 1e-12 if v != 0.0 else 0.0 for v in column] for column in per] for per in columns]
    worst_share, worst_at, compared = 0.0, None, 0
    linear_ok = True
    for s in range(CHANNELS):
        source = work / f"segments-{s}.f64"
        drive = [0.0] * (frames * CHANNELS)
        for _, at in segments:
            drive[at * CHANNELS + s] = amplitude
        write_f64(source, drive)
        run(runner, fold_art, rate, source, work / f"folded-{s}.f64", 48, script)
        got = read_f64(work / f"folded-{s}.f64")
        for o in range(CHANNELS):
            reference = [0.0] * frames
            slack = [0.0] * frames
            for name, at in segments:
                matrix = written.get(name)
                if o in phones:
                    path = [(s, 1.0)]                    # headphones: never folded
                elif o in speakers or outs.get(o, ("", []))[0] == "sub":
                    path = [(d, gain(matrix, d, s)) for d in range(CHANNELS) if gain(matrix, d, s) != 0.0]
                else:
                    path = []
                tail = frames - at
                for d, g in path:
                    reference[at:] = [x + g * y for x, y in zip(reference[at:], columns[d][o][:tail])]
                    slack[at:] = [x + abs(g) * y for x, y in zip(slack[at:], halves[d][o][:tail])]
            column = got[o::CHANNELS]
            for n in range(frames):
                bound = 0.5 * ulp32(column[n]) + slack[n] + 1e-30
                share = abs(column[n] - reference[n]) / bound
                compared += 1
                if share > worst_share:
                    worst_share, worst_at = share, (s + 1, n, o + 1)
                if share > 1.0:
                    linear_ok = False
    report(linear_ok, "linear through bass management",
           f"{compared} samples (16 inputs x 5000 frames x 16 outputs, 5 folds a run) match the model; worst "
           f"{worst_share:.4f} of its bound at input {worst_at[0]} frame {worst_at[1]} output {worst_at[2]}"
           if linear_ok else
           f"input {worst_at[0]} frame {worst_at[1]} output {worst_at[2]} is {worst_share:.3g} times its bound")

    # (d) byte identity on full.
    sine = work / "sine.f64"
    write_f64(sine, [0.5 * math.sin(2 * math.pi * 997.0 * n / rate + c * 0.37)
                     for n in range(frames) for c in range(CHANNELS)])
    plain = run(runner, plain_art, rate, sine, work / "sine-plain.f64", 48)
    with_section = run(runner, fold_art, rate, sine, work / "sine-section.f64", 48)
    full_script = work / "full.script"
    full_script.write_text("0 fold speakers full\n0 fold phones full\n1000 fold 0 full\n2000 fold 1 full\n")
    asked_full = run(runner, fold_art, rate, sine, work / "sine-full.f64", 7, full_script)
    identical = plain == with_section == asked_full
    report(identical, "full is the artifact without the section",
           f"{len(plain)} bytes identical: --no-monitor, the section with no script, and a script asking only "
           "for full at --block 7" if identical else "the outputs differ")

    # (c) the crossfade, bit for bit, on the flat speakers.
    flat_art = compile_preset(work, "fold-flat", rate)
    _, flat_outs, _, flat_folds = read_section(flat_art.read_text())
    order = {name: [(d, s, g) for d, s, g in rows] for (set_index, name), rows in flat_folds.items() if set_index == 0}
    order["full"] = None
    # The last request comes 201 frames into the crossfade back to full, so it
    # waits: it starts at the first block top after frame 3280, which is 3281
    # at --block 7 and 3289 at --block 48 (blocks are split at event frames).
    events = [(100, "5.1"), (1000, "stereo"), (1900, "mono"), (2800, "full"), (3001, "stereo")]
    xframes = 4400
    dc = [(c + 1) / 32.0 for c in range(CHANNELS)]
    dc_in = work / "dc.f64"
    write_f64(dc_in, dc * xframes)
    xscript = work / "crossfade.script"
    xscript.write_text("".join(f"{at} fold speakers {name}\n" for at, name in events))
    flat_speakers = [o for o, (role, _) in flat_outs.items() if role == "speaker"]
    subs = [o for o, (role, _) in flat_outs.items() if role == "sub"]
    run(runner, flat_art, rate, dc_in, work / "dc-full.f64", 48)
    dc_full = read_f64(work / "dc-full.f64")

    def apply(name):
        if order[name] is None:
            return list(dc)
        view = [0.0] * CHANNELS
        for d, s, g in order[name]:
            view[d] = view[d] + g * dc[s]
        return view

    def model(block):
        """DspStage's documented arithmetic, on the runner's block splits.
        Also returns, per frame and output, |B - A| / N of the crossfade
        running at that frame (0 when none is)."""
        out = [0.0] * (xframes * CHANNELS)
        allowed = [0.0] * (xframes * CHANNELS)
        current, target, remaining, a = "full", None, 0, 0.0
        step = 1.0 / ramp
        request, pending, done = "full", list(events), 0
        while done < xframes:
            while pending and pending[0][0] == done:
                request = pending.pop(0)[1]
            frames_now = min(block, xframes - done)
            if pending:
                frames_now = min(frames_now, pending[0][0] - done)
            if remaining == 0 and request != current:
                target, remaining, a = request, ramp, 0.0
            for n in range(done, done + frames_now):
                if remaining > 0:
                    a += step
                    remaining -= 1
                    if remaining == 0:
                        a = 1.0
                    va, vb = apply(current), apply(target)
                    view = [(1.0 - a) * x + a * y for x, y in zip(va, vb)]
                    for o in flat_speakers:
                        allowed[n * CHANNELS + o] = abs(vb[o] - va[o]) / ramp
                    if remaining == 0:
                        current = target
                else:
                    view = apply(current)
                for o in flat_speakers:
                    out[n * CHANNELS + o] = view[o]
            done += frames_now
        return float32(out), allowed

    for block in (48, 7):
        run(runner, flat_art, rate, dc_in, work / f"dc-fold-{block}.f64", block, xscript)
        got = read_f64(work / f"dc-fold-{block}.f64")
        expect, allowed = model(block)
        mismatch = [i for i in range(xframes * CHANNELS) if i % CHANNELS in flat_speakers and got[i] != expect[i]]
        report(not mismatch, f"crossfade arithmetic (block {block})",
               f"{xframes * len(flat_speakers)} speaker samples identical to the documented arithmetic, "
               "including a request deferred past a crossfade" if not mismatch else
               f"{len(mismatch)} samples differ, first at frame {mismatch[0] // CHANNELS} output {mismatch[0] % CHANNELS + 1}")
        sub_still = all(got[n * CHANNELS + o] == dc_full[n * CHANNELS + o] for n in range(xframes) for o in subs)
        report(sub_still, f"the LFE passes every fold (block {block})",
               f"subs {[o + 1 for o in subs]} are byte for byte the full run's" if sub_still else "a sub moved")
    got = read_f64(work / "dc-fold-48.f64")
    _, allowed = model(48)
    worst, worst_at, largest = 0.0, None, 0.0
    bounded = True
    for n in range(1, xframes):
        for o in flat_speakers:
            i = n * CHANNELS + o
            moved = abs(got[i] - got[i - CHANNELS])
            if moved == 0.0:
                continue
            bound = allowed[i] + ulp32(max(abs(got[i]), abs(got[i - CHANNELS])))
            largest = max(largest, moved)
            if moved / bound > worst:
                worst, worst_at = moved / bound, (n, o + 1)
            if moved > bound:
                bounded = False
    report(bounded, "no click (DC through every crossfade)",
           f"largest step {largest:.4e}; worst share of |B - A| / {ramp} + 1 ulp is {worst:.8f} at frame "
           f"{worst_at[0]} output {worst_at[1]}" if bounded else
           f"frame {worst_at[0]} output {worst_at[1]} stepped {worst:.3f} times its bound")

    print(f"verify-fold: {'all passed' if failures == 0 else f'{failures} FAILED'} ({rate} Hz, crossfade {ramp})")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
