#!/usr/bin/env python3
"""Compare saved event evidence with the bounded pinned-core wire reference."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent
reference = [list(map(int, line.split())) for line in
             (ROOT / 'reference-window.txt').read_text().splitlines()]
audio = json.loads((ROOT / 'capture/1-audio.json').read_text())
capture = audio['eventCapture']
assert capture['triggeredEvents'] == 1 and capture['omittedEvents'] == 0
assert capture['continuityBreaks'] == 0
event, = capture['events']
assert event['channel'] == 4 and event['zeroFrames'] == 7
assert event['windowComplete'] and not event['windowCapacityReached']
assert event['termination'] == 'nonzero'
assert len(reference) == len(event['frames']) == 39
offset = event['startInputFrame'] - 3304775
live = []
for row, frame in zip(reference, event['frames']):
    assert row[0] + offset == frame['inputFrame']
    # Decode exact captured Float32 bits rather than JSON's rounded display.
    values = [struct.unpack('<f', struct.pack('<I', b))[0] for b in frame['sampleBits']]
    assert len(values) == len(frame['samples']) == 16
    live.append([v * 8388608 for v in values])

channels = []
for c in range(16):
    expected = [r[c + 1] for r in reference]
    measured = [row[c] for row in live]
    errors = [a - b for a, b in zip(measured, expected)]
    channels.append({'channel': c + 1,
        'matchingNearestL24Codes': sum(round(a) == b for a, b in zip(measured, expected)),
        'frames': len(reference), 'maximumRawErrorLSB': max(map(abs, errors)),
        'rmsRawErrorLSB': (sum(e * e for e in errors) / len(errors)) ** 0.5,
        'liveZeroFrames': sum(v == 0 for v in measured)})
assert channels[3]['matchingNearestL24Codes'] == 39
assert channels[3]['liveZeroFrames'] == 7
assert all(c['liveZeroFrames'] == 0 for c in channels if c['channel'] != 4)
start_stamp = event['frames'][16]
result = {'classification': 'live event matches predicted quantization neighborhood',
    'acceptance': 'old gate still failed; no retrospective pass',
    'referenceStartSourceFrame': 3304775, 'liveStartInputFrame': event['startInputFrame'],
    'inputIndexMinusSourceIndex': offset,
    'note': 'Index offset aligns this waveform; it is not a loaded impulse latency result.',
    'startTiming': {k: v for k, v in start_stamp.items() if k not in ('samples', 'sampleBits')},
    'channels': channels,
    'channel4ReferenceL24Codes': [r[4] for r in reference],
    'channel4LiveFloatInLSBs': [r[3] for r in live],
    'hashes': {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in
        ['capture/1-audio.json', 'reference-window.cpp', 'reference-window.txt']}}
(ROOT / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'channel4': channels[3],
                  'maxRawErrorAllChannelsLSB': max(c['maximumRawErrorLSB'] for c in channels),
                  'inputIndexMinusSourceIndex': offset}, indent=2))
