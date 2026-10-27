"""Tests for soak_reference.py: the evidence rules and the comparison, on
synthetic captures with a reference made here, and the exporter's stimulus
against an independent implementation.
Run: python3 -m unittest work/dante-mode/test_soak_reference.py"""
import copy
import json
import random
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

import soak_reference as sr

HERE = Path(__file__).resolve().parent
SECONDS = 10
TOTAL = SECONDS * 48000
LAG = 600          # stimulus frame = input frame - LAG


def reference_codes(first, count, zero_runs):
    """Deterministic 24-bit codes for stimulus frames [first, first+count); `zero_runs`
    is {channel: [(start_frame, length)]} in stimulus frames."""
    rows = []
    for frame in range(first, first + count):
        rng = random.Random(frame)
        row = [rng.randint(-200000, 200000) or 7 for _ in range(16)]
        for channel, runs in zero_runs.items():
            if any(start <= frame < start + length for start, length in runs):
                row[channel] = 0
        rows.append(row)
    return rows


class FakeReference:
    def __init__(self, zero_runs):
        self.zero_runs = zero_runs

    def row(self, frame):
        return reference_codes(frame, 1, self.zero_runs)[0]


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def capture_frame(input_frame, row, noise=0.0):
    """What the Mac records for a reference row: the host's gain, as float32."""
    values = [(code * sr.HOST_GAIN + (noise if code else 0.0)) / 8388608 for code in row]
    return {'inputFrame': input_frame, 'inputSampleTime': input_frame + 1000,
            'outputCallbackFirstFrame': (input_frame - 16) // 32 * 32, 'outputCallbackFrames': 32,
            'outputCallbackSampleTime': (input_frame - 16) // 32 * 32 + 1000 + 200,
            'sampleBits': [bits(v) for v in values]}


def event(channel, start_input, length, zero_runs, lag=LAG, noise=0.0):
    rows = reference_codes(start_input - 16 - lag, 32 + length, zero_runs)
    frames = [capture_frame(start_input - 16 + i, row, noise) for i, row in enumerate(rows)]
    return {'channel': channel + 1, 'startInputFrame': start_input, 'zeroFrames': length, 'termination': 'nonzero',
            'windowComplete': True, 'windowCapacityReached': False, 'frames': frames}


def report(events, longest=None, rate=48000):
    longest = longest or {}
    total = SECONDS * rate
    for e in events:
        longest[e['channel'] - 1] = max(longest.get(e['channel'] - 1, 0), e['zeroFrames'])
    return {
        'kind': 'continuous-activity-not-latency', 'amplitude': 0.1, 'warmupSeconds': 2, 'seconds': SECONDS,
        'inputFrames': total, 'outputFrames': total, 'inputDiscontinuities': 0, 'outputDiscontinuities': 0,
        'invalidBuffers': 0, 'invalidTimestamps': 0,
        'sampleRate': rate,
        'device': {'nominalSampleRate': rate, 'input': {'channels': 16}, 'output': {'channels': 16}},
        'eventCapture': {'version': 1, 'stimulus': 'xorshift32-interleaved-float32', 'stimulusSeed': 0x9e3779b9,
                         'beforeFrames': 16, 'afterFrames': 16, 'thresholdFrames': 4, 'frameLimitPerEvent': 96,
                         'eventLimit': 32, 'omittedEvents': 0, 'continuityBreaks': 0,
                         'triggeredEvents': len(events), 'events': events},
        'channels': [{'samples': total - 2 * rate, 'nonFinite': 0, 'fullScaleSamples': 0, 'peak': 0.02, 'rms': 0.005,
                      'longestZeroRun': longest.get(c, 1)} for c in range(16)],
    }


RUNS = {3: [(200000 - LAG, 5), (300000 - LAG, 9)], 12: [(250000 - LAG, 4)]}


def good_events():
    return [event(3, 200000, 5, RUNS), event(12, 250000, 4, RUNS), event(3, 300000, 9, RUNS)]


def check(rep, runs=RUNS):
    try:
        events = sr.validate_evidence(rep)
    except sr.EvidenceError as error:
        return {'status': 'inconclusive', 'reason': str(error)}
    return sr.check_windows(rep, events, FakeReference(runs))


class EvidenceTests(unittest.TestCase):
    def test_a_capture_with_no_long_zero_run_has_no_events(self):
        result = check(report([]))
        self.assertEqual(result['status'], 'no-events')

    def test_predicted_runs_match_at_one_alignment(self):
        result = check(report(good_events()))
        self.assertEqual(result['status'], 'matched-events', result.get('reason'))
        self.assertEqual(result['inputIndexMinusSourceIndex'], LAG)
        self.assertEqual([e['zeroFrames'] for e in result['events']], [5, 4, 9])
        self.assertLess(max(e['maximumErrorLSB'] for e in result['events']), 0.5)

    def test_small_conversion_error_is_tolerated_but_not_on_the_zeros(self):
        events = [event(3, 200000, 5, RUNS, noise=1.5)]
        self.assertEqual(check(report(events))['status'], 'matched-events')
        self.assertEqual(check(report([event(3, 200000, 5, RUNS, noise=2.6)]))['status'], 'mismatch')

    def test_a_run_the_preset_does_not_produce_is_a_mismatch(self):
        # The capture has five zeros on channel 4 where the reference has signal: a hole.
        hole = event(3, 220000, 5, {3: [(220000 - LAG, 5)]})
        result = check(report([hole]))
        self.assertEqual(result['status'], 'mismatch')
        self.assertIn('unexplained sample', result['reason'])

    def test_a_run_longer_or_shorter_than_predicted_is_a_mismatch(self):
        for length in (4, 6):
            captured = event(3, 200000, length, {3: [(200000 - LAG, length)]})
            result = check(report([captured]))        # the reference has five there
            self.assertEqual(result['status'], 'mismatch', length)

    def test_an_alignment_that_moves_between_runs_is_a_mismatch(self):
        moved_runs = {3: [(200000 - LAG, 5)], 12: [(250000 - LAG - 3, 4)]}
        events = [event(3, 200000, 5, moved_runs), event(12, 250000, 4, moved_runs, lag=LAG + 3)]
        result = check(report(events), moved_runs)
        self.assertEqual(result['status'], 'mismatch')
        self.assertIn('alignment moved by 3 frames', result['reason'])

    def test_audio_that_is_not_the_stimulus_is_a_mismatch(self):
        other = event(3, 200000, 5, RUNS)
        rng = random.Random(99)
        for frame in other['frames']:
            frame['sampleBits'] = [bits(rng.uniform(-0.02, 0.02)) if b else 0 for b in frame['sampleBits']]
        result = check(report([other]))
        self.assertEqual(result['status'], 'mismatch')
        self.assertIn('not the stimulus', result['reason'])

    def test_incomplete_or_inconsistent_evidence_is_inconclusive_never_a_pass(self):
        cases = {}
        rep = report(good_events()); rep['eventCapture']['omittedEvents'] = 3; cases['omitted'] = rep
        rep = report(good_events()); rep['inputDiscontinuities'] = 1; cases['discontinuity'] = rep
        rep = report(good_events()); rep['inputFrames'] -= 48; cases['short'] = rep
        rep = report(good_events()); rep['seconds'] = 7200; cases['too long'] = rep
        rep = report(good_events()); rep['channels'][7]['longestZeroRun'] = 6; cases['run without a record'] = rep
        rep = report(good_events()); rep['channels'][3]['longestZeroRun'] = 30; cases['longer run not retained'] = rep
        rep = report(good_events()); rep['channels'][5]['peak'] = 0.0; cases['silent channel'] = rep
        rep = report(good_events()); rep['eventCapture']['events'][0]['windowComplete'] = False; cases['window'] = rep
        rep = report(good_events()); del rep['eventCapture']['events'][1]['frames'][5]; cases['missing frame'] = rep
        rep = report(good_events()); rep['eventCapture']['events'][0]['frames'][20]['sampleBits'][3] = bits(0.001); cases['metadata'] = rep
        rep = report(good_events()); rep['eventCapture']['stimulusSeed'] = 1; cases['seed'] = rep
        for name, rep in cases.items():
            self.assertEqual(check(rep)['status'], 'inconclusive', name)

    def test_search_is_bounded(self):
        late = event(3, 200000, 5, {3: [(200000 - 20000, 5)]}, lag=20000)   # further back than the search allows
        self.assertEqual(check(report([late]), {3: [(200000 - 20000, 5)]})['status'], 'mismatch')

    def test_the_capture_rate_comes_from_the_report(self):
        self.assertEqual(check(report(good_events(), rate=96000))['status'], 'matched-events')
        # A 48 kHz capture's frame counts read as 96 kHz ones are incomplete, not a pass.
        short = report(good_events())
        short['device']['nominalSampleRate'] = short['sampleRate'] = 96000
        self.assertIn('incomplete frame counts', check(short)['reason'])
        odd = report([], rate=22050)
        self.assertIn('unsupported sample rate', check(odd)['reason'])
        disagree = report([])
        disagree['sampleRate'] = 96000
        self.assertIn('disagree', check(disagree)['reason'])
        older = report(good_events())
        del older['sampleRate']        # reports from before 2026-10-17 carry only the device's rate
        self.assertEqual(check(older)['status'], 'matched-events')

    def test_ranges_merge_and_cover_each_window(self):
        events = sr.validate_evidence(report(good_events()))
        spans = sr.reference_ranges(events, TOTAL)
        self.assertEqual(len(spans), 3)
        for (lo, hi), e in zip(spans, events):
            self.assertLessEqual(lo, e['frames'][0]['inputFrame'] - LAG)
            self.assertGreaterEqual(hi, e['frames'][-1]['inputFrame'] - LAG + 1)


class ExporterTests(unittest.TestCase):
    def test_the_exporter_reproduces_the_stimulus_through_a_unity_preset(self):
        unity = HERE / 'config' / 'dsp-unity.dsp'
        with tempfile.TemporaryDirectory() as scratch:
            data, provenance = sr.export_reference(unity, [(0, 4), (1000, 1002)], Path(scratch), 48000)
        self.assertEqual(len(data), 6 * 64)
        self.assertEqual(provenance['artifactSHA256'], sr.sha(unity))
        # An independent xorshift32 in Python, float32 arithmetic by round-tripping through struct.
        f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]
        state = 0x9e3779b9
        expected = {}
        for frame in range(1002):
            row = []
            for _ in range(16):
                state ^= (state << 13) & 0xffffffff; state ^= state >> 17; state ^= (state << 5) & 0xffffffff
                signed = state - (1 << 32) if state & 0x80000000 else state
                sent = f32(max(-1.0, min(1.0, f32(f32(float(signed)) / f32(float(2**31 - 1))))) * f32(0.1))
                row.append(round(sent * sr.HOST_GAIN * 8388608))
            expected[frame] = row
        got = [list(struct.unpack_from('<16i', data, i * 64)) for i in range(6)]
        for index, frame in enumerate([0, 1, 2, 3, 1000, 1001]):
            for c in range(16):
                self.assertLessEqual(abs(got[index][c] - expected[frame][c]), 1, (frame, c))   # ties may round either way
        self.assertTrue(all(abs(v) <= 838861 for row in got for v in row))

    def test_the_artifact_must_be_compiled_for_the_capture_rate(self):
        unity48 = (HERE / 'config' / 'dsp-unity.dsp').read_text()
        self.assertIn('\nrate 48000\n', unity48)
        with tempfile.TemporaryDirectory() as scratch:
            unity96 = Path(scratch) / 'unity96.dsp'
            unity96.write_text(unity48.replace('\nrate 48000\n', '\nrate 96000\n'))
            at96, _ = sr.export_reference(unity96, [(0, 4)], Path(scratch), 96000)
            at48, _ = sr.export_reference(HERE / 'config' / 'dsp-unity.dsp', [(0, 4)], Path(scratch), 48000)
            self.assertEqual(at96, at48)      # unity is the stimulus at any rate
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                sr.export_reference(HERE / 'config' / 'dsp-unity.dsp', [(0, 4)], Path(scratch), 96000)
            self.assertIn(b'compiled for rate 48000', raised.exception.stderr)
            # Through analyze: a 96 kHz capture against the 48 kHz artifact is inconclusive, never a pass.
            rep = Path(scratch) / 'report.json'
            rep.write_text(json.dumps(report(good_events(), rate=96000)))
            result = sr.analyze(rep, HERE / 'config' / 'dsp-unity.dsp', Path(scratch))
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIn('compiled for rate 48000', result['reason'])

    def test_a_bad_artifact_is_inconclusive(self):
        with tempfile.TemporaryDirectory() as scratch:
            bad = Path(scratch) / 'bad.dsp'
            bad.write_text('not an artifact\n')
            rep = Path(scratch) / 'report.json'
            rep.write_text(json.dumps(report(good_events())))
            result = sr.analyze(rep, bad, Path(scratch))
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIn('reference export failed', result['reason'])


if __name__ == '__main__':
    unittest.main()
