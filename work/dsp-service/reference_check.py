#!/usr/bin/env python3
"""Offline reference-v1 checker for retained loaded-DSP event windows.

Never opens audio, contacts the Pi, modifies legacy results or accepts a whole
run. The 2-LSB bound is fixed for this diagnostic policy, not fitted to each
window; the USB host conversion model still needs prospective validation.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess

from deploy import checked_bundle
from validate import issues, verify_snapshot

ROOT = Path(__file__).resolve().parents[2]
POLICY = {'id': 'loaded-event-reference-v1', 'maximumErrorLSB': 2.0,
          'maximumSearchLagFrames': 9600, 'minimumAnchorRangeLSB': 256,
          'inputModel': 's24-nearest', 'gainFitting': False,
          'alignment': 'one integer offset for all channels and events',
          'zeroRunRule': 'exact predicted L24 zero codes with nonzero boundaries',
          'coverage': 'retained event windows only', 'wholeRunValidated': False}
PINS = {
    'candidate/bridge': '406699bd4cf5763defb3560dca3d447d1dd2e8928dc370a643f1a080be026c88',
    'candidate/loaded.dsp': '2b6baa0484a7d9a7d7a39f189d772a6864a473163c6e8098723954b652bb456c',
    'work/phase4-bridge/src/bridge_core.cpp': '111094f46366a1f7285f3cc6cfef4779505a1cb3048af3b1ccb041f3cb9d2fcb',
    'work/phase4-bridge/include/usb16x16/bridge_core.hpp': '23cd778849504f3975f41a2245af358249fd43359c1047f8c7426502c4f32d37',
}


class EvidenceError(ValueError):
    """Missing, unsupported or incomplete evidence; never a pass."""


class SignalMismatch(ValueError):
    """Complete evidence does not agree with the fixed reference policy."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def decode(frame):
    bits = frame['sampleBits']
    require(len(bits) == 16 and all(integer(b, 0, 2**32 - 1) for b in bits), 'invalid sample bits')
    values = [struct.unpack('<f', struct.pack('<I', b))[0] for b in bits]
    require(all(math.isfinite(v) and abs(v) < 1 for v in values), 'invalid or full-scale sample')
    return [v * 8388608 for v in values]


def validate_evidence(report):
    require(report['kind'] == 'continuous-activity-not-latency', 'unsupported stimulus report')
    require(report['amplitude'] == 0.1 and report['warmupSeconds'] == 2, 'unsupported amplitude/warmup')
    require(integer(report['seconds'], 5, 600), 'unsupported duration')
    total = report['seconds'] * 48000
    require(report['inputFrames'] == report['outputFrames'] == total, 'incomplete frame counts')
    for key in ('inputDiscontinuities', 'outputDiscontinuities', 'invalidBuffers', 'invalidTimestamps'):
        require(report[key] == 0, 'capture integrity error: ' + key)
    device = report['device']
    require(device['nominalSampleRate'] == 48000, 'unsupported sample rate')
    for direction in ('input', 'output'):
        require(device[direction]['channels'] == 16, 'unsupported channel count')
    ec = report['eventCapture']
    for key, expected in dict(version=1, stimulus='xorshift32-interleaved-float32',
            stimulusSeed=0x9e3779b9, beforeFrames=16, afterFrames=16, thresholdFrames=4,
            frameLimitPerEvent=96, eventLimit=32, omittedEvents=0, continuityBreaks=0).items():
        require(ec[key] == expected, 'unsupported/incomplete event evidence: ' + key)
    events = ec['events']
    require(len(events) <= 32 and ec['triggeredEvents'] == len(events), 'missing event records')
    longest = [0] * 16
    input_origin = output_origin = None
    identities = set()
    seen_frames = {}
    for event in events:
        c, start, run = event['channel'], event['startInputFrame'], event['zeroFrames']
        require(integer(c, 1, 16) and integer(start, 96000, total - 1) and integer(run, 4, 64),
                'invalid event coordinates')
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
            origins = (frame['inputSampleTime'] - frame['inputFrame'],
                       frame['outputCallbackSampleTime'] - first)
            if input_origin is None:
                input_origin, output_origin = origins
            require(origins == (input_origin, output_origin), 'timestamp/stimulus mapping changed')
            identity = (tuple(frame['sampleBits']), frame['inputSampleTime'], first,
                        frame['outputCallbackSampleTime'], count)
            prior = seen_frames.setdefault(frame['inputFrame'], identity)
            require(prior == identity, 'overlapping event windows contradict each other')
            values.append(decode(frame))
        require(all(values[i][c - 1] == 0 for i in range(16, 16 + run)) and
                values[15][c - 1] != 0 and values[16 + run][c - 1] != 0,
                'zero-run metadata contradicts sample bits')
        longest[c - 1] = max(longest[c - 1], run)
    require(len(report['channels']) == 16, 'missing aggregate channels')
    for c, stats in enumerate(report['channels']):
        require(integer(stats['longestZeroRun'], 0, total - 96000), 'invalid aggregate zero-run length')
        require(stats['samples'] == total - 96000 and stats['nonFinite'] == stats['fullScaleSamples'] == 0,
                'invalid aggregate signal evidence')
        require(math.isfinite(stats['peak']) and 1e-8 <= stats['peak'] < 1 and
                math.isfinite(stats['rms']) and 0 < stats['rms'] <= stats['peak'], 'inactive/invalid return')
        if longest[c] or stats['longestZeroRun'] >= 4:
            require(stats['longestZeroRun'] == longest[c], 'unrepresented longest zero run')
    return events


def search_bounds(event, total):
    frame = event['frames'][0]
    estimate = int(frame['outputCallbackFirstFrame'] + frame['inputSampleTime'] -
                   frame['outputCallbackSampleTime'])
    return max(0, estimate - POLICY['maximumSearchLagFrames']), min(total - len(event['frames']) + 1, estimate + 1)


def reference_ranges(report):
    spans = []
    for event in validate_evidence(report):
        lo, hi = search_bounds(event, report['outputFrames'])
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


def check_windows(report, reference):
    result = {'policy': POLICY, 'status': 'inconclusive', 'wholeRunValidated': False,
              'coveredInputFrames': 0, 'events': [], 'evidenceComplete': False}
    try:
        events = validate_evidence(report)
        result['evidenceComplete'] = True
        if not events:
            result['reason'] = 'no retained windows; waveform not evaluated'
            return result
        common_offset = None
        covered = set()
        for event in events:
            values = [decode(f) for f in event['frames']]
            anchors = [c for c in range(16) if c != event['channel'] - 1 and
                       max(v[c] for v in values[:16]) - min(v[c] for v in values[:16]) >=
                       POLICY['minimumAnchorRangeLSB']]
            require(anchors, 'insufficient independent alignment signal')
            anchor = anchors[0]  # fixed channel order, chosen without reference fitting
            lo, hi = search_bounds(event, report['outputFrames'])
            matches = []
            for first in range(lo, hi):
                if all(abs(values[i][anchor] - reference.row(first + i)[anchor]) <=
                       POLICY['maximumErrorLSB'] for i in range(16)):
                    matches.append(first)
            if not matches:
                raise SignalMismatch('no reference alignment within fixed search/tolerance limits')
            require(len(matches) == 1, 'ambiguous reference alignment')
            first, = matches
            offset = event['frames'][0]['inputFrame'] - first
            if common_offset is not None and common_offset != offset:
                raise SignalMismatch('sample alignment changed between event windows')
            common_offset = offset
            maximum = 0.0
            for i, row in enumerate(values):
                expected = reference.row(first + i)
                error = max(abs(row[c] - expected[c]) for c in range(16))
                maximum = max(maximum, error)
                if error > POLICY['maximumErrorLSB']:
                    raise SignalMismatch(f'unexplained sample at input frame {event["frames"][i]["inputFrame"]}')
            c, run = event['channel'] - 1, event['zeroFrames']
            if any(reference.row(first + i)[c] != 0 for i in range(16, 16 + run)) or \
                    reference.row(first + 15)[c] == 0 or reference.row(first + 16 + run)[c] == 0:
                raise SignalMismatch('observed zero run is not exactly predicted by L24 reference')
            result['events'].append({'channel': c + 1, 'startInputFrame': event['startInputFrame'],
                'referenceStartFrame': first + 16, 'zeroFrames': run, 'alignmentAnchorChannel': anchor + 1,
                'maximumErrorLSB': maximum, 'matchedFrames': len(values)})
            covered.update(f['inputFrame'] for f in event['frames'])
        result.update(status='matched-events', inputIndexMinusSourceIndex=common_offset,
                      coveredInputFrames=len(covered))
    except SignalMismatch as error:
        result.update(status='mismatch', reason=str(error))
    except (EvidenceError, KeyError, TypeError, OverflowError, struct.error) as error:
        result.update(status='inconclusive', reason=str(error))
    return result


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_pins(manifest):
    for path, digest in PINS.items():
        observed = manifest['files'][path] if path.startswith('candidate/') else sha(ROOT / path)
        require(observed == digest, 'reference policy source/artifact pin mismatch: ' + path)


def criterion_identity(manifest):
    check_pins(manifest)
    definition = {'policy': POLICY, 'pins': PINS, 'checker': sha(Path(__file__)),
                  'exporter': sha(ROOT / 'work/dsp-service/reference-export.cpp'),
                  'validator': sha(ROOT / 'work/dsp-service/validate.py')}
    digest = hashlib.sha256(json.dumps(definition, sort_keys=True).encode()).hexdigest()
    return {'id': POLICY['id'], 'sha256': digest}


def explains_zero_gate(result, report):
    # This only clears the activity test's zero-run objection. All other
    # validation remains in force, and unsaved samples stay unverified.
    return result.get('transportAndActivity') == 'passed' and result.get('evidenceComplete') is True and (
        result['status'] == 'matched-events' or
        (not report['eventCapture']['events'] and result['status'] == 'inconclusive'))


def analyze(run, bundle, output):
    output.mkdir(parents=True, exist_ok=False)
    result = {'status': 'inconclusive', 'wholeRunValidated': False, 'policy': POLICY}
    try:
        manifest = checked_bundle(bundle)
        check_pins(manifest)
        report = json.loads((run / '1-audio.json').read_text())
        before, after = [json.loads((run / name).read_text()) for name in ('1-before.json', '1-after.json')]
        expected = (bundle / 'candidate/aes67.conf').read_text().replace('PROFILE=dsp-direct\n', 'PROFILE=dsp-loaded\n', 1)
        verify_snapshot(before, manifest, 'loaded', expected)
        verify_snapshot(after, manifest, 'loaded', expected)
        invariant_errors = issues(before, after, report, 'loaded', list(range(1, 17)), zero_run_gate=False)
        require(not invariant_errors, 'transport/activity checks failed: ' + '; '.join(invariant_errors))
        spans = reference_ranges(report)
        data = b''
        provenance = {}
        if spans:
            ranges = output / 'ranges.txt'
            ranges.write_text(''.join(f'{lo} {hi}\n' for lo, hi in spans))
            source = ROOT / 'work/dsp-service/reference-export.cpp'
            core = ROOT / 'work/phase4-bridge/src/bridge_core.cpp'
            binary = output / 'reference-export'
            command = ['clang++', '-std=c++20', '-O2', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                       '-I', str(ROOT / 'work/phase4-bridge/include'), str(source), str(core), '-o', str(binary)]
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=90)
            artifact = bundle / 'candidate/loaded.dsp'
            with (output / 'reference.s32le').open('xb') as stream:
                subprocess.run([str(binary), str(artifact), str(ranges)], check=True,
                               stdout=stream, stderr=subprocess.PIPE, timeout=300)
            data = (output / 'reference.s32le').read_bytes()
            provenance = {str(p.relative_to(ROOT)): sha(p) for p in (source, core, artifact,
                ROOT / 'work/phase4-bridge/include/usb16x16/bridge_core.hpp')}
            provenance['compiler'] = subprocess.check_output(['clang++', '--version'], text=True).splitlines()[0]
            provenance['binarySHA256'] = sha(binary)
            provenance['referenceSHA256'] = hashlib.sha256(data).hexdigest()
        result = check_windows(report, Reference(spans, data))
        result.update(transportAndActivity='passed', legacyGateErrors=issues(before, after, report, 'loaded', list(range(1, 17))),
                      provenance=provenance, reportSHA256=sha(run / '1-audio.json'),
                      checkerSHA256=sha(Path(__file__)), ranges=spans,
                      acceptance='not established; unsaved samples were not compared')
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        result.update(status='inconclusive', reason=str(error))
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.run.resolve(), args.bundle.resolve(), args.output.resolve())
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['status'] == 'matched-events' else 1)
