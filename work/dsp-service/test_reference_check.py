import copy
import json
from pathlib import Path
import random
import struct
import unittest
from unittest.mock import patch

import reference_check as checker

ROOT = Path(__file__).resolve().parents[2]
LIVE = ROOT / 'outputs/dsp-service/event-capture-20260911/capture/1-audio.json'


def set_samples(frame, codes):
    values = [v / 8388608 for v in codes]
    frame['sampleBits'] = [struct.unpack('<I', struct.pack('<f', v))[0] for v in values]
    frame['samples'] = values


def make_event(reference, source_start=200, offset=989, run=7):
    frames = []
    for source in range(source_start - 16, source_start + run + 16):
        index = source + offset + 96000
        output = index // 64 * 64
        frame = {'inputFrame': index, 'inputSampleTime': index + 10000,
                 'outputCallbackFirstFrame': output, 'outputCallbackSampleTime': output + 10252,
                 'outputCallbackFrames': 64}
        set_samples(frame, reference[source])
        frames.append(frame)
    return {'channel': 4, 'startInputFrame': source_start + offset + 96000, 'zeroFrames': run,
            'termination': 'nonzero', 'windowComplete': True, 'windowCapacityReached': False,
            'frames': frames}


class ReferenceCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = json.loads(LIVE.read_text())
        randomizer = random.Random(101)
        cls.rows = [[randomizer.randint(-200000, 200000) for _ in range(16)] for _ in range(2048)]
        for start in (200, 500):
            for i in range(start, start + 7):
                cls.rows[i][3] = 0
        data = bytes(96000 * 64) + b''.join(struct.pack('<16i', *row) for row in cls.rows)
        cls.reference = checker.Reference([(0, 98048)], data)

    def report(self):
        report = copy.deepcopy(self.original)
        report['eventCapture']['events'] = [make_event(self.rows)]
        return report

    def test_quantization_matches_without_whole_run_acceptance(self):
        result = checker.check_windows(self.report(), self.reference)
        self.assertEqual(result['status'], 'matched-events', result)
        self.assertEqual(result['inputIndexMinusSourceIndex'], 989)
        self.assertEqual(result['coveredInputFrames'], 39)
        self.assertFalse(result['wholeRunValidated'])

    def test_injected_silence_is_rejected(self):
        report = self.report()
        for frame in report['eventCapture']['events'][0]['frames'][24:29]:
            set_samples(frame, [0] * 16)
        self.assertEqual(checker.check_windows(report, self.reference)['status'], 'mismatch')

    def test_missing_or_repeated_sample_inside_zero_span_is_rejected(self):
        # Channel 4 is already zero at the edit; the other 15 channels reveal
        # the lost/repeated frame. Timestamps deliberately remain uninterrupted.
        for shift in (-1, 1):
            with self.subTest(shift=shift):
                report = self.report()
                report['eventCapture']['events'] = [make_event(self.rows, run=7 - shift)]
                report['channels'][3]['longestZeroRun'] = 7 - shift
                frames = report['eventCapture']['events'][0]['frames']
                for i in range(18, len(frames)):
                    set_samples(frames[i], self.rows[200 - 16 + i + shift])
                result = checker.check_windows(report, self.reference)
                self.assertEqual(result['status'], 'mismatch', result)

    def test_zero_rule_is_stricter_than_general_two_lsb_tolerance(self):
        rows = copy.deepcopy(self.rows)
        rows[202][3] = 1  # an unexpected zero must not hide in the error tolerance
        reference = checker.Reference([(0, 98048)], bytes(96000 * 64) + b''.join(struct.pack('<16i', *r) for r in rows))
        result = checker.check_windows(self.report(), reference)
        self.assertEqual(result['status'], 'mismatch')
        self.assertIn('not exactly predicted', result['reason'])

    def test_channel_swap_and_gain_change_are_rejected(self):
        for mutation in ('swap', 'gain'):
            report = self.report()
            for i, frame in enumerate(report['eventCapture']['events'][0]['frames']):
                codes = self.rows[184 + i].copy()
                if mutation == 'swap':
                    codes[0], codes[1] = codes[1], codes[0]
                else:
                    codes = [v * 0.5 for v in codes]
                set_samples(frame, codes)
            self.assertEqual(checker.check_windows(report, self.reference)['status'], 'mismatch')

    def test_alignment_cannot_change_between_windows(self):
        for offset in (989, 990):
            report = self.report()
            report['eventCapture']['events'].append(make_event(self.rows, source_start=500, offset=offset))
            report['eventCapture']['triggeredEvents'] = 2
            result = checker.check_windows(report, self.reference)
            self.assertEqual(result['status'], 'matched-events' if offset == 989 else 'mismatch', result)

    def test_truncated_omitted_missing_and_invalid_evidence_is_inconclusive(self):
        def incomplete(r): r['eventCapture']['events'][0]['windowComplete'] = False
        def omitted(r): r['eventCapture']['omittedEvents'] = 1
        def timestamp(r): r['eventCapture']['events'][0]['frames'][20]['inputSampleTime'] += 1
        def invalid_time(r): r['invalidTimestamps'] = 1
        def missing(r): r['eventCapture']['events'][0]['frames'].pop()
        def seed(r): r['eventCapture']['stimulusSeed'] = 123
        def longest(r): r['channels'][3]['longestZeroRun'] = 8
        for mutation in (incomplete, omitted, timestamp, invalid_time, missing, seed, longest):
            with self.subTest(mutation=mutation.__name__):
                report = self.report()
                mutation(report)
                self.assertEqual(checker.check_windows(report, self.reference)['status'], 'inconclusive')

    def test_no_events_does_not_claim_waveform_validation(self):
        report = self.report()
        report['eventCapture']['events'] = []
        report['eventCapture']['triggeredEvents'] = 0
        report['channels'][3]['longestZeroRun'] = 1
        result = checker.check_windows(report, checker.Reference([], b''))
        self.assertEqual(result['status'], 'inconclusive')
        self.assertEqual(result['coveredInputFrames'], 0)

    def test_source_pin_mismatch_refuses_reference(self):
        manifest = {'files': {p: h for p, h in checker.PINS.items() if p.startswith('candidate/')}}
        with patch.object(checker, 'sha', return_value='wrong'):
            with self.assertRaisesRegex(checker.EvidenceError, 'pin mismatch'):
                checker.check_pins(manifest)

    def test_reference_truncation_is_rejected(self):
        with self.assertRaises(checker.EvidenceError):
            checker.Reference([(0, 10)], b'')

    def test_real_saved_window_matches_retained_reference_fixture(self):
        # Fill unused search context with silence; the CLI separately regenerates
        # the entire search interval through the pinned DSP core.
        report = copy.deepcopy(self.original)
        spans = checker.reference_ranges(report)
        lo, hi = spans[0]
        data = bytearray((hi - lo) * 64)
        fixture = ROOT / 'outputs/dsp-service/event-capture-20260911/reference-window.txt'
        for line in fixture.read_text().splitlines():
            frame, *codes = map(int, line.split())
            struct.pack_into('<16i', data, (frame - lo) * 64, *codes)
        result = checker.check_windows(report, checker.Reference(spans, bytes(data)))
        self.assertEqual(result['status'], 'matched-events', result)
        self.assertEqual(result['inputIndexMinusSourceIndex'], 989)

    def test_ambiguous_alignment_does_not_pass(self):
        rows = copy.deepcopy(self.rows)
        rows[500:539] = copy.deepcopy(rows[184:223])
        reference = checker.Reference([(0, 98048)], bytes(96000 * 64) + b''.join(struct.pack('<16i', *r) for r in rows))
        result = checker.check_windows(self.report(), reference)
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIn('ambiguous', result['reason'])

    def test_activity_waiver_requires_complete_evidence_and_invariants(self):
        report = self.report()
        result = checker.check_windows(report, self.reference)
        self.assertFalse(checker.explains_zero_gate(result, report))
        result['transportAndActivity'] = 'passed'
        self.assertTrue(checker.explains_zero_gate(result, report))
        result['evidenceComplete'] = False
        self.assertFalse(checker.explains_zero_gate(result, report))
        report['eventCapture']['events'] = []
        report['eventCapture']['triggeredEvents'] = 0
        report['channels'][3]['longestZeroRun'] = 1
        result = checker.check_windows(report, checker.Reference([], b''))
        result['transportAndActivity'] = 'passed'
        self.assertTrue(checker.explains_zero_gate(result, report))
        self.assertFalse(result['wholeRunValidated'])


if __name__ == '__main__':
    unittest.main()
