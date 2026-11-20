"""Tests for soak_reference.py: the evidence rules and the comparison, on
synthetic captures with a reference made here, and the exporter's stimulus
against an independent implementation.
Run: python3 -m unittest dante/test_soak_reference.py"""
import contextlib
import copy
import io
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
GAIN = struct.unpack('<f', struct.pack('<f', 0.999998))[0]   # the Mac's gain each way on 2026-10-10


def gain_file(directory, output=GAIN, input_=GAIN, rate=48000, kind='host-gain'):
    path = Path(directory) / f'gain-{output}-{input_}-{rate}-{kind}.json'
    path.write_text(json.dumps({'kind': kind, 'sampleRate': rate,
                                'hostGain': {'outputGain': output, 'inputGain': input_}}))
    return path


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
    values = [(code * GAIN + (noise if code else 0.0)) / 8388608 for code in row]
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
    return sr.check_windows(rep, events, FakeReference(runs), GAIN)


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

    def test_a_narrower_loop_judges_only_its_channels(self):
        # 2026-10-29: 8 channels looped at 96 kHz. Channels 9-16 return silence: the
        # harness opens one capped event on each, and their statistics read silent.
        runs = {3: RUNS[3]}
        events = [event(3, 200000, 5, runs), event(3, 300000, 9, runs)]
        for e in events:
            for frame in e['frames']:
                frame['sampleBits'][8:] = [0] * 8
        silent = []
        for c in range(8, 16):
            frames = [capture_frame(96000 - 16 + i, [0] * 16) for i in range(96)]
            silent.append({'channel': c + 1, 'startInputFrame': 96000, 'zeroFrames': TOTAL - 96000,
                           'termination': 'captureEnd', 'windowComplete': False, 'windowCapacityReached': True,
                           'frames': frames})
        rep = report(events)
        rep['eventCapture']['events'] = events + silent
        rep['eventCapture']['triggeredEvents'] = len(events) + len(silent)
        for c in range(8, 16):
            rep['channels'][c].update(peak=0.0, longestZeroRun=TOTAL - 96000)
        self.assertEqual(check(rep, runs)['status'], 'inconclusive')
        looped = sr.validate_evidence(rep, loop=8)
        self.assertEqual([e['channel'] for e in looped], [4, 4])
        result = sr.check_windows(rep, looped, FakeReference(runs), GAIN, loop=8)
        self.assertEqual(result['status'], 'matched-events', result.get('reason'))
        # A hole on a looped channel is still a hole.
        hole = event(5, 220000, 5, {5: [(220000 - LAG, 5)]})
        for frame in hole['frames']:
            frame['sampleBits'][8:] = [0] * 8
        rep['eventCapture']['events'].append(hole)
        rep['eventCapture']['triggeredEvents'] += 1
        rep['channels'][5]['longestZeroRun'] = 5
        looped = sr.validate_evidence(rep, loop=8)
        self.assertEqual(sr.check_windows(rep, looped, FakeReference(runs), GAIN, loop=8)['status'], 'mismatch')
        with self.assertRaises(sr.EvidenceError):
            sr.validate_evidence(rep, loop=0)

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
            data, provenance = sr.export_reference(unity, [(0, 4), (1000, 1002)], Path(scratch), 48000, GAIN)
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
                row.append(round(sent * GAIN * 8388608))
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
            at96, _ = sr.export_reference(unity96, [(0, 4)], Path(scratch), 96000, GAIN)
            at48, _ = sr.export_reference(HERE / 'config' / 'dsp-unity.dsp', [(0, 4)], Path(scratch), 48000, GAIN)
            self.assertEqual(at96, at48)      # unity is the stimulus at any rate
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                sr.export_reference(HERE / 'config' / 'dsp-unity.dsp', [(0, 4)], Path(scratch), 96000, GAIN)
            self.assertIn(b'compiled for rate 48000', raised.exception.stderr)
            # Through analyze: a 96 kHz capture against the 48 kHz artifact is inconclusive, never a pass.
            rep = Path(scratch) / 'report.json'
            rep.write_text(json.dumps(report(good_events(), rate=96000)))
            result = sr.analyze(rep, HERE / 'config' / 'dsp-unity.dsp', Path(scratch), gain_file(scratch, rate=96000))
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIn('compiled for rate 48000', result['reason'])

    def test_the_exporter_follows_the_measured_output_gain(self):
        unity = HERE / 'config' / 'dsp-unity.dsp'
        with tempfile.TemporaryDirectory() as scratch:
            then, _ = sr.export_reference(unity, [(0, 64)], Path(scratch), 48000, GAIN)
            now, _ = sr.export_reference(unity, [(0, 64)], Path(scratch), 48000, 1.0)
            with self.assertRaises(subprocess.CalledProcessError):
                sr.export_reference(unity, [(0, 4)], Path(scratch), 48000, 0.5)
        then = struct.unpack(f'<{64 * 16}i', then)
        now = struct.unpack(f'<{64 * 16}i', now)
        self.assertNotEqual(then, now)    # 0.1 full scale is 838,861 codes: 2e-6 of it is a code or two
        self.assertLessEqual(max(abs(a - b) for a, b in zip(then, now)), 2)
        self.assertTrue(all(abs(b) >= abs(a) for a, b in zip(then, now)))

    def test_the_host_gain_must_be_a_measurement_at_the_capture_rate(self):
        with tempfile.TemporaryDirectory() as scratch:
            self.assertEqual(sr.host_gain(gain_file(scratch, 1.0, 1.0), 48000), (1.0, 1.0))
            self.assertEqual(sr.host_gain(gain_file(scratch, kind='bit-exact-24'), 48000), (GAIN, GAIN))
            for bad, reason in ((gain_file(scratch, rate=96000), 'another rate'),
                                (gain_file(scratch, 0.5, 1.0), 'not near unity'),
                                (gain_file(scratch, kind='continuous-activity-not-latency'), 'unsupported')):
                with self.assertRaises(sr.EvidenceError) as raised:
                    sr.host_gain(bad, 48000)
                self.assertIn(reason, str(raised.exception))
            rep = Path(scratch) / 'report.json'
            rep.write_text(json.dumps(report([])))
            result = sr.analyze(rep, HERE / 'config' / 'dsp-unity.dsp', Path(scratch), gain_file(scratch, 1.0, 1.0))
            self.assertEqual(result['status'], 'no-events')
            self.assertEqual(result['hostGain'], {'output': 1.0, 'input': 1.0})
            self.assertEqual(result['policy']['id'], 'dante-event-reference-v2')

    def test_a_bad_artifact_is_inconclusive(self):
        with tempfile.TemporaryDirectory() as scratch:
            bad = Path(scratch) / 'bad.dsp'
            bad.write_text('not an artifact\n')
            rep = Path(scratch) / 'report.json'
            rep.write_text(json.dumps(report(good_events())))
            result = sr.analyze(rep, bad, Path(scratch), gain_file(scratch))
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIn('reference export failed', result['reason'])


MONITOR_SECTION = """monitor 1
sets 1
set main speakers
outs 4
out 0 speaker 0
out 1 speaker 0
out 2 speaker 0
out 3 sub 0
label 0 L
label 1 R
expandsets 16
0
0
0
0
-
-
-
-
-
-
-
-
-
-
-
-
folds 1
fold 0 swap 4
0 1 1
1 0 1
2 2 1
3 3 1
end
"""
QUIET = 0.0000035     # output 3's gain: about 3 codes at unity, under one at -12 dB, so it sits at zero in runs


def monitor_artifact(directory, section=True):
    """dsp-unity.dsp with output 3 made quiet and, with `section`, a monitor section: one speakers
    set on outputs 1-4 (4 the sub), whose fold `swap` exchanges inputs 1 and 2."""
    text = (HERE / 'config' / 'dsp-unity.dsp').read_text()
    assert text.endswith('\n15 0 1 0\nend\n') and '\n2 0 1 0\n' in text
    text = text.replace('\n2 0 1 0\n', f'\n2 0 {QUIET} 0\n')
    if section:
        text = text[:-len('end\n')] + MONITOR_SECTION
    path = Path(directory) / ('monitor.dsp' if section else 'plain.dsp')
    path.write_text(text)
    return path


def monitor_state(directory, level='-12.0', fold='full', name='state', mute=None):
    lines = ['MONITOR-STATE v=1 seq=7', 'active=main', 'dim_db=-20.0', 'subs=on',
             f'set id=main level_db={level} trim_db=0.0 dim=0 mute=0 fold={fold}',
             'solo=' + ','.join('0' * 16), 'mute=' + ','.join(mute or '0' * 16), 'end']
    path = Path(directory) / f'{name}.txt'
    path.write_text('\n'.join(lines) + '\n')
    return path


def monitor_limits(directory, max_db):
    path = Path(directory) / 'limits.txt'
    path.write_text(f'MONITOR-LIMITS v=1\nmax_db={max_db}\nstart=last\nstart_db=-30.0\nlock=0\nend\n')
    return path


SPAN = (100000, 130000)   # stimulus frames exported, after the harness's warm-up; runs are taken from
FIRST_RUN = 110016        # here on, so the checker's search (up to 9,600 frames back) stays inside SPAN


def exported_rows(artifact, scratch, state=None, limits=None):
    data, provenance = sr.export_reference(artifact, [SPAN], Path(scratch), 48000, 1.0, state, limits)
    rows = {SPAN[0] + i: list(struct.unpack_from('<16i', data, i * 64)) for i in range(SPAN[1] - SPAN[0])}
    return rows, provenance


def real_events(rows, channel=2, count=2):
    """Synthetic captures of the first `count` zero runs (4 to 64 long) the reference has on `channel`:
    what the Mac records when the wire carries exactly `rows`, LAG frames late."""
    events, frame = [], FIRST_RUN
    while len(events) < count and frame < SPAN[1] - 100:
        if rows[frame][channel] == 0 and rows[frame - 1][channel] != 0:
            run = 0
            while rows[frame + run][channel] == 0:
                run += 1
            if 4 <= run <= 64:
                first = frame - 16
                frames = [capture_frame(first + i + LAG, rows[first + i]) for i in range(32 + run)]
                events.append({'channel': channel + 1, 'startInputFrame': frame + LAG, 'zeroFrames': run,
                               'termination': 'nonzero', 'windowComplete': True, 'windowCapacityReached': False,
                               'frames': frames})
                frame += 200
            frame += run
        frame += 1
    assert len(events) == count, 'the test preset gave too few zero runs'
    return events


def judge(rows_for_capture, reference_rows):
    """check_windows on captures of `rows_for_capture` against `reference_rows` (no exporter run)."""
    class Rows:
        def row(self, frame):
            if frame not in reference_rows:
                raise sr.EvidenceError('reference does not cover requested source frame')
            return reference_rows[frame]
    rep = report(real_events(rows_for_capture))
    return sr.check_windows(rep, sr.validate_evidence(rep), Rows(), GAIN)


class MonitorTests(unittest.TestCase):
    """2026-11-20: the monitor block in the reference, resolved by the owner's monitor_ctl."""

    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        d = cls.scratch.name
        cls.artifact = monitor_artifact(d)
        cls.unity, _ = exported_rows(cls.artifact, d)
        cls.minus12, cls.minus12_provenance = exported_rows(cls.artifact, d, monitor_state(d))
        cls.swapped, _ = exported_rows(cls.artifact, d, monitor_state(d, fold='swap', name='swap'))

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def test_without_a_state_the_reference_is_as_before(self):
        d = self.scratch.name
        # No section and a section with no state: the same bytes (the stage on full, the gains at unity).
        plain, _ = exported_rows(monitor_artifact(d, section=False), d)
        self.assertEqual(plain, self.unity)
        # A state at 0 dB on full plays exactly that too: the at-rest gain of 1 is exact.
        at_unity, provenance = exported_rows(self.artifact, d, monitor_state(d, level='0.0', name='unity'))
        self.assertEqual(at_unity, self.unity)
        self.assertIn('MONITOR applied seq=7 active=main', provenance['monitorResolved'])
        # A state with an artifact that has no section is not used, as the owner ignores it.
        ignored, provenance = exported_rows(monitor_artifact(d, section=False), d, monitor_state(d))
        self.assertEqual(ignored, self.unity)
        self.assertIn('no monitor section', provenance['monitorResolved'])
        # And through analyze, a case of the tests above: unchanged, with the monitor recorded as unused.
        rep = Path(d) / 'empty-report.json'
        rep.write_text(json.dumps(report([])))
        result = sr.analyze(rep, HERE / 'config' / 'dsp-unity.dsp', Path(d), gain_file(d, 1.0, 1.0))
        self.assertEqual(result['status'], 'no-events')
        self.assertEqual(result['monitor']['state'], None)
        self.assertIn('no monitor section', result['monitor']['model'])
        self.assertEqual(judge(self.unity, self.unity)['status'], 'matched-events')

    def test_a_capture_at_minus_12_db_matches_only_with_the_state(self):
        self.assertIn('gain_db=-12.0', self.minus12_provenance['monitorResolved'])
        self.assertIn('gains=0.251188643,0.251188643,0.251188643,0.251188643,1,', self.minus12_provenance['monitorResolved'])
        for frame in (SPAN[0], SPAN[0] + 999):     # outputs 1-4 at -12 dB, the rest untouched
            self.assertEqual(self.minus12[frame][4:], self.unity[frame][4:])
            self.assertAlmostEqual(self.minus12[frame][0], self.unity[frame][0] * 10 ** (-12 / 20), delta=1)
        self.assertEqual(judge(self.minus12, self.minus12)['status'], 'matched-events')
        without = judge(self.minus12, self.unity)
        self.assertEqual(without['status'], 'mismatch')
        self.assertIn('not the stimulus', without['reason'])
        # End to end, with the exporter: matched with the state, a mismatch without it.
        d = self.scratch.name
        rep = Path(d) / 'minus12.json'
        rep.write_text(json.dumps(report(real_events(self.minus12))))
        gain = gain_file(d, 1.0, GAIN)
        state = monitor_state(d)
        result = sr.analyze(rep, self.artifact, Path(d), gain, monitor_state=state)
        self.assertEqual(result['status'], 'matched-events', result.get('reason'))
        self.assertEqual(result['monitor']['state'], {'path': str(state), 'sha256': sr.sha(state)})
        self.assertIn('gain_db=-12.0', result['monitor']['resolved'])
        result = sr.analyze(rep, self.artifact, Path(d), gain)
        self.assertEqual(result['status'], 'mismatch')
        self.assertIn('no state was given', result['monitor']['model'])

    def test_the_limits_are_applied(self):
        d = self.scratch.name
        capped, provenance = exported_rows(self.artifact, d, monitor_state(d), monitor_limits(d, '-14.0'))
        self.assertIn('limits=file max_db=-14.0', provenance['monitorResolved'])
        self.assertIn('gain_db=-14.0', provenance['monitorResolved'])
        self.assertEqual(judge(capped, capped)['status'], 'matched-events')
        self.assertEqual(judge(capped, self.minus12)['status'], 'mismatch')
        with self.assertRaises(sr.EvidenceError):
            sr.export_reference(self.artifact, [SPAN], Path(d), 48000, 1.0, None, monitor_limits(d, '-20.0'))

    def test_a_fold_other_than_full(self):
        # `swap` puts input 2 on output 1 and input 1 on output 2, at the state's -12 dB.
        for frame in (SPAN[0], SPAN[0] + 999):
            self.assertEqual(self.swapped[frame][0], self.minus12[frame][1])
            self.assertEqual(self.swapped[frame][1], self.minus12[frame][0])
            self.assertEqual(self.swapped[frame][2:], self.minus12[frame][2:])
        self.assertEqual(judge(self.swapped, self.swapped)['status'], 'matched-events')
        self.assertEqual(judge(self.swapped, self.minus12)['status'], 'mismatch')

    def test_a_state_or_limits_the_owner_would_refuse_cannot_decide(self):
        d = self.scratch.name
        rep = Path(d) / 'refused.json'
        rep.write_text(json.dumps(report(real_events(self.minus12))))
        gain = gain_file(d, 1.0, GAIN)
        good = monitor_state(d)
        malformed = Path(d) / 'malformed.txt'
        malformed.write_text(good.read_text().replace('level_db=-12.0', 'level_db=-12'))
        out_of_range = Path(d) / 'range.txt'
        out_of_range.write_text(good.read_text().replace('level_db=-12.0', 'level_db=-90.0'))
        bad_limits = Path(d) / 'bad-limits.txt'
        bad_limits.write_text('MONITOR-LIMITS v=1\nmax_db=-50.0\nend\n')
        for name, state, limits, why in (('malformed', malformed, None, 'monitor state refused'),
                                         ('out of range', out_of_range, None, 'monitor state refused'),
                                         ('absent', Path(d) / 'none.txt', None, 'No such file'),
                                         ('bad limits', good, bad_limits, 'monitor limits refused'),
                                         ('limits alone', None, monitor_limits(d, '-20.0'), 'without a monitor state')):
            result = sr.analyze(rep, self.artifact, Path(d), gain, monitor_state=state, monitor_limits=limits)
            self.assertEqual(result['status'], 'inconclusive', name)
            self.assertIn(why, result['reason'], name)
        args = [str(rep), str(self.artifact), '--host-gain', str(gain), '--monitor-state', str(malformed)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sr.main(args), 2)
            self.assertEqual(sr.main(args[:-1] + [str(good)]), 0)


if __name__ == '__main__':
    unittest.main()
