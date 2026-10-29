#!/usr/bin/env python3
"""The soak criterion for a Dante preset whose outputs can legitimately sit
at zero: every run of zeros the Mac captured must be one the preset produces.

A soak (`measure-candidate.sh soak`) fails a channel that returns four or
more exact zeros in a row, because on a full-band channel that is a hole. A
bass-managed preset breaks the rule honestly: a subwoofer output is slow and
small, and stays within half a code of zero for several samples now and then
(an hour of the harness's noise through `loaded.dsp` gives runs of 13 with no
transport at all). This criterion keeps the rule's purpose and drops its
assumption. The harness's stimulus is deterministic and its report keeps a
window of all sixteen channels around every such run; this program
regenerates what the Dante wire should carry from the installed artifact
(owner/reference_export.cpp, the owner's own conversion path) and requires,
for every run:

  - one alignment, found on another channel in the sixteen frames before the
    run, and the same alignment for every run in the capture (a dropped or
    repeated frame anywhere between two runs moves it);
  - every sample of all sixteen channels in the window within 2 codes of the
    reference;
  - the zeros themselves exactly where the reference has zeros, with a
    non-zero on each side: an unexpected zero cannot hide in the tolerance.

It is the bridge's "loaded event reference criterion v1"
(work/dsp-service/REFERENCE_VALIDATION.md, reference_check.py) carried to the
Dante owner, with three differences: any artifact, not one pinned preset;
captures up to an hour; and macOS's gain each way modelled rather than left
to the tolerance. v2 (2026-10-27) takes that gain from a measurement (the
harness's `hostgain` report, or a `bitexact` one) instead of the fixed
0.999998 of v1, because the Mac's gain on this device has been 0.999998
(2026-10-10) and unity (2026-10-27). Like v1 it is an activity criterion,
not whole-stream verification: samples outside the windows are not compared.

  soak_reference.py REPORT.json ARTIFACT.dsp --host-gain GAIN.json [--output DIR]

Exit 0 only for `matched-events` or `no-events` with the capture's own
integrity checks passing; 1 for a mismatch; 2 for evidence that cannot
decide (never a pass). Opens no audio and contacts nothing.
"""
import argparse
import hashlib
import json
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EXPORTER = HERE / 'owner' / 'reference_export.cpp'
CORE = HERE.parent / 'phase4-bridge' / 'src' / 'bridge_core.cpp'
INCLUDE = HERE.parent / 'phase4-bridge' / 'include'
POLICY = {'id': 'dante-event-reference-v2', 'maximumErrorLSB': 2.0, 'maximumSearchLagFrames': 9600,
          'minimumAnchorRangeLSB': 256, 'inputModel': 'measured host output gain, nearest 24-bit',
          'returnModel': 'measured host input gain', 'gainFitting': False,
          'alignment': 'one integer offset for all channels and events',
          'zeroRunRule': 'exact predicted zero codes with nonzero boundaries',
          'coverage': 'retained event windows only', 'wholeRunValidated': False,
          'maximumSeconds': 3600}
DANTE_RATES = (44100, 48000, 88200, 96000, 176400, 192000)


class EvidenceError(ValueError):
    """Missing, unsupported or incomplete evidence; never a pass."""


class SignalMismatch(ValueError):
    """Complete evidence does not agree with the reference."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def decode(frame):
    """One captured frame as sixteen values in 24-bit codes (not rounded)."""
    bits = frame['sampleBits']
    require(len(bits) == 16 and all(integer(b, 0, 2**32 - 1) for b in bits), 'invalid sample bits')
    values = [struct.unpack('<f', struct.pack('<I', b))[0] for b in bits]
    require(all(math.isfinite(v) and abs(v) < 1 for v in values), 'invalid or full-scale sample')
    return [v * 8388608 for v in values]


def host_gain(path, rate):
    """(output gain, input gain) from the harness's `hostgain` or `bitexact` report, measured
    at the capture's rate."""
    gain_report = json.loads(Path(path).read_text())
    require(gain_report.get('kind') in ('host-gain', 'bit-exact-24'), 'unsupported host gain report')
    require(gain_report.get('sampleRate') == rate, 'the host gain was measured at another rate')
    gain = gain_report['hostGain']
    output, input_ = gain['outputGain'], gain['inputGain']
    require(all(type(g) in (int, float) and abs(g - 1) < 1e-4 for g in (output, input_)),
            'host gain missing or not near unity')
    return float(output), float(input_)


def report_rate(report):
    """The rate the capture ran at: the device's nominal rate, which the
    harness's own sampleRate (since 2026-10-17) must agree with."""
    rate = report['device']['nominalSampleRate']
    require(rate in DANTE_RATES, 'unsupported sample rate')
    require(report.get('sampleRate', rate) == rate, 'sampleRate and the device rate disagree')
    return int(rate)


def validate_evidence(report, loop=16):
    """The capture is whole and its event records are self-consistent. Returns the events.
    Only channels 1..loop are looped back (2026-10-29: 8 at 96 kHz, where MADI halves):
    the rest return silence, so their events and statistics are not evidence and are left out."""
    require(integer(loop, 1, 16), 'unsupported loop width')
    require(report.get('kind') == 'continuous-activity-not-latency', 'unsupported stimulus report')
    require(report['amplitude'] == 0.1 and report['warmupSeconds'] == 2, 'unsupported amplitude/warmup')
    require(integer(report['seconds'], 5, POLICY['maximumSeconds']), 'unsupported duration')
    rate = report_rate(report)
    total = report['seconds'] * rate
    warmup = report['warmupSeconds'] * rate
    require(report['inputFrames'] == report['outputFrames'] == total, 'incomplete frame counts')
    for key in ('inputDiscontinuities', 'outputDiscontinuities', 'invalidBuffers', 'invalidTimestamps'):
        require(report[key] == 0, 'capture integrity error: ' + key)
    device = report['device']
    for direction in ('input', 'output'):
        require(device[direction]['channels'] == 16, 'unsupported channel count')
    ec = report['eventCapture']
    for key, expected in dict(version=1, stimulus='xorshift32-interleaved-float32', stimulusSeed=0x9e3779b9,
                              beforeFrames=16, afterFrames=16, thresholdFrames=4, frameLimitPerEvent=96,
                              continuityBreaks=0).items():
        require(ec[key] == expected, 'unsupported event evidence: ' + key)
    # More runs than the harness keeps windows for is a capture this cannot judge, not a failure of the audio.
    require(ec['omittedEvents'] == 0, f"{ec['omittedEvents']} zero runs were not retained (the harness keeps "
                                      f"{ec['eventLimit']}); shorten the soak or raise the harness's limit")
    events = ec['events']
    require(ec['triggeredEvents'] == len(events) <= ec['eventLimit'], 'missing event records')
    longest = [0] * 16
    origin = None
    identities = set()
    seen = {}
    looped = []
    for event in events:
        c, start, run = event['channel'], event['startInputFrame'], event['zeroFrames']
        require(integer(c, 1, 16), 'invalid event coordinates')
        if c > loop:
            continue
        looped.append(event)
        require(integer(start, warmup, total - 1) and integer(run, 4, 64), 'invalid event coordinates')
        require((c, start) not in identities, 'duplicate event')
        identities.add((c, start))
        require(event['windowComplete'] is True and event['windowCapacityReached'] is False and
                event['termination'] == 'nonzero', 'incomplete event window')
        frames = event['frames']
        require(len(frames) == 32 + run, 'missing window frames')
        values = []
        for i, frame in enumerate(frames):
            require(frame['inputFrame'] == start - 16 + i and 0 <= frame['inputFrame'] < total,
                    'noncontiguous frame indices')
            for key in ('inputSampleTime', 'outputCallbackSampleTime'):
                t = frame[key]
                require(type(t) in (int, float) and math.isfinite(t) and float(t).is_integer(),
                        'missing or invalid timestamp')
            count, first = frame['outputCallbackFrames'], frame['outputCallbackFirstFrame']
            require(count in (32, 64) and integer(first, 0, total - count) and first % count == 0,
                    'invalid output callback mapping')
            origins = (frame['inputSampleTime'] - frame['inputFrame'], frame['outputCallbackSampleTime'] - first)
            origin = origin or origins
            require(origins == origin, 'timestamp/stimulus mapping changed')
            identity = (tuple(frame['sampleBits']), frame['inputSampleTime'], first,
                        frame['outputCallbackSampleTime'], count)
            require(seen.setdefault(frame['inputFrame'], identity) == identity,
                    'overlapping event windows contradict each other')
            values.append(decode(frame))
        require(all(values[i][c - 1] == 0 for i in range(16, 16 + run)) and
                values[15][c - 1] != 0 and values[16 + run][c - 1] != 0,
                'zero-run metadata contradicts sample bits')
        longest[c - 1] = max(longest[c - 1], run)
    require(len(report['channels']) == 16, 'missing aggregate channels')
    for c, stats in enumerate(report['channels'][:loop]):
        require(stats['samples'] == total - warmup and stats['nonFinite'] == stats['fullScaleSamples'] == 0,
                f'channel {c + 1}: short, non-finite or full-scale')
        require(math.isfinite(stats['peak']) and 1e-8 <= stats['peak'] < 1, f'channel {c + 1}: silent or invalid')
        if longest[c] or stats['longestZeroRun'] >= 4:
            require(stats['longestZeroRun'] == longest[c], f'channel {c + 1}: its longest zero run has no event record')
    return looped


def search_bounds(event, total):
    """Where in the stimulus this window can have come from: at or before the
    output callback paired with its first frame, by at most the search lag."""
    frame = event['frames'][0]
    estimate = int(frame['outputCallbackFirstFrame'] + frame['inputSampleTime'] - frame['outputCallbackSampleTime'])
    return max(0, estimate - POLICY['maximumSearchLagFrames']), min(total - len(event['frames']) + 1, estimate + 1)


def reference_ranges(events, total):
    spans = []
    for event in events:
        lo, hi = search_bounds(event, total)
        require(hi > lo, 'empty reference search interval')
        spans.append((lo, hi + len(event['frames']) - 1))
    merged = []
    for lo, hi in sorted(spans):
        if merged and lo <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(hi, merged[-1][1]))
        else:
            merged.append((lo, hi))
    return merged


class Reference:
    """The exporter's output: 24-bit codes for the requested stimulus frames."""

    def __init__(self, spans, data):
        require(len(data) == sum(hi - lo for lo, hi in spans) * 64, 'incomplete reference export')
        self.spans = spans
        self.data = data

    def row(self, frame):
        offset = 0
        for lo, hi in self.spans:
            if lo <= frame < hi:
                return struct.unpack_from('<16i', self.data, (offset + frame - lo) * 64)
            offset += hi - lo
        raise EvidenceError('reference does not cover requested source frame')


def check_windows(report, events, reference, input_gain, loop=16):
    """Every event against the reference. Returns the result; raises nothing."""
    result = {'policy': POLICY, 'status': 'inconclusive', 'wholeRunValidated': False,
              'coveredInputFrames': 0, 'events': []}
    limit = POLICY['maximumErrorLSB']
    try:
        if not events:
            result.update(status='no-events', reason='no zero run of four or more on any channel')
            return result
        common = None
        covered = set()
        for event in events:
            values = [decode(f) for f in event['frames']]
            channel, run = event['channel'] - 1, event['zeroFrames']
            anchors = [c for c in range(loop) if c != channel and
                       max(v[c] for v in values[:16]) - min(v[c] for v in values[:16]) >= POLICY['minimumAnchorRangeLSB']]
            require(anchors, 'no other channel carries enough signal to align on')
            anchor = anchors[0]   # fixed channel order, chosen without looking at the reference
            lo, hi = search_bounds(event, report['outputFrames'])
            matches = [first for first in range(lo, hi)
                       if all(abs(values[i][anchor] - reference.row(first + i)[anchor] * input_gain) <= limit for i in range(16))]
            if not matches:
                raise SignalMismatch(f'channel {channel + 1} at input frame {event["startInputFrame"]}: '
                                     'the frames before the zero run are not the stimulus through this preset')
            require(len(matches) == 1, 'ambiguous reference alignment')
            first = matches[0]
            offset = event['frames'][0]['inputFrame'] - first
            if common is not None and common != offset:
                raise SignalMismatch(f'alignment moved by {offset - common} frames before input frame '
                                     f'{event["startInputFrame"]}: frames were lost or repeated')
            common = offset
            worst = 0.0
            for i, row in enumerate(values):
                expected = reference.row(first + i)
                error = max(abs(row[c] - expected[c] * input_gain) for c in range(loop))
                worst = max(worst, error)
                if error > limit:
                    raise SignalMismatch(f'unexplained sample at input frame {event["frames"][i]["inputFrame"]} '
                                         f'({error:.2f} codes from the reference)')
            if any(reference.row(first + i)[channel] != 0 for i in range(16, 16 + run)) or \
                    reference.row(first + 15)[channel] == 0 or reference.row(first + 16 + run)[channel] == 0:
                raise SignalMismatch(f'channel {channel + 1} at input frame {event["startInputFrame"]}: '
                                     f'{run} zeros where the preset does not produce exactly {run}')
            result['events'].append({'channel': channel + 1, 'startInputFrame': event['startInputFrame'],
                                     'referenceStartFrame': first + 16, 'zeroFrames': run,
                                     'alignmentAnchorChannel': anchor + 1, 'maximumErrorLSB': round(worst, 4),
                                     'matchedFrames': len(values)})
            covered.update(f['inputFrame'] for f in event['frames'])
        result.update(status='matched-events', inputIndexMinusSourceIndex=common, coveredInputFrames=len(covered))
    except SignalMismatch as error:
        result.update(status='mismatch', reason=str(error))
    except (EvidenceError, KeyError, TypeError, OverflowError, struct.error) as error:
        result.update(status='inconclusive', reason=str(error))
    return result


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def export_reference(artifact, spans, work, rate, output_gain):
    """Build the exporter and run it over `spans`. Returns (bytes, provenance)."""
    binary = work / 'reference_export'
    command = ['c++', '-std=c++20', '-O2', '-Wall', '-Wextra', '-Wpedantic', '-Werror', '-I', str(EXPORTER.parent),
               '-I', str(INCLUDE), str(EXPORTER), str(CORE), '-o', str(binary)]
    subprocess.run(command, check=True, capture_output=True, text=True, timeout=180)
    ranges = work / 'ranges.txt'
    ranges.write_text(''.join(f'{lo} {hi}\n' for lo, hi in spans))
    done = subprocess.run([str(binary), str(artifact), str(ranges), str(rate), repr(output_gain)], check=True, capture_output=True, timeout=1800)
    provenance = {'exporterSHA256': sha(EXPORTER), 'coreSHA256': sha(CORE), 'artifactSHA256': sha(artifact),
                  'referenceSHA256': hashlib.sha256(done.stdout).hexdigest(),
                  'compiler': subprocess.check_output(['c++', '--version'], text=True).splitlines()[0]}
    return done.stdout, provenance


def analyze(report_path, artifact, work, gain_path, loop=16):
    result = {'policy': POLICY, 'status': 'inconclusive', 'wholeRunValidated': False}
    try:
        report = json.loads(Path(report_path).read_text())
        events = validate_evidence(report, loop)
        output_gain, input_gain = host_gain(gain_path, report_rate(report))
        result['evidenceComplete'] = True
        if events:
            spans = reference_ranges(events, report['outputFrames'])
            data, provenance = export_reference(artifact, spans, work, report_rate(report), output_gain)
            result = check_windows(report, events, Reference(spans, data), input_gain, loop)
            result.update(evidenceComplete=True, provenance=provenance, ranges=spans)
        else:
            result = check_windows(report, events, None, input_gain, loop)
            result['evidenceComplete'] = True
        result.update(hostGain={'output': output_gain, 'input': input_gain}, hostGainSHA256=sha(gain_path),
                      loopChannels=loop)
        result.update(reportSHA256=sha(report_path), checkerSHA256=sha(__file__), artifact=str(artifact),
                      seconds=report['seconds'],
                      longestZeroRuns=[c['longestZeroRun'] for c in report['channels']])
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode() if isinstance(error.stderr, bytes) else (error.stderr or '')
        result.update(status='inconclusive', reason=f'reference export failed: {detail.strip()[:300]}')
    except (EvidenceError, KeyError, TypeError, OSError, ValueError, subprocess.SubprocessError) as error:
        result.update(status='inconclusive', reason=str(error))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('report', type=Path, help="the harness's continuous report (a soak's JSON)")
    parser.add_argument('artifact', type=Path, help='the preset the endpoint ran, as installed')
    parser.add_argument('--host-gain', type=Path, required=True,
                        help="the harness's hostgain (or bitexact) report, measured at the capture's rate")
    parser.add_argument('--output', type=Path, help='write result.json here (the directory is created)')
    parser.add_argument('--loop-channels', type=int, default=16,
                        help='only channels 1..N are looped back and judged (default 16)')
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory() as scratch:
        result = analyze(args.report, args.artifact, Path(scratch), args.host_gain, args.loop_channels)
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    events = result.get('events', [])
    by_channel = {}
    for event in events:
        by_channel.setdefault(event['channel'], []).append(event['zeroFrames'])
    print(f"reference: {result['status']}" + (f" - {result['reason']}" if result.get('reason') else ''))
    if events:
        print('  ' + '; '.join(f"ch{c}: {len(runs)} run(s), longest {max(runs)}" for c, runs in sorted(by_channel.items())) +
              f"; worst error {max(e['maximumErrorLSB'] for e in events):.2f} codes; one alignment "
              f"({result.get('inputIndexMinusSourceIndex')} frames) for all {len(events)}")
    return 0 if result['status'] in ('matched-events', 'no-events') else 1 if result['status'] == 'mismatch' else 2


if __name__ == '__main__':
    sys.exit(main())
