#!/usr/bin/env python3
"""The standing battery for a bridge change, against the running service and
no bundle: a 60 s all-16 continuous preflight (the noise probe: a Mac hole is
a zero run on a return), four 800-impulse latency runs, a 600 s all-16 soak.
Reuses validate.py's snapshot() and issues(): the Pi is read only before and
after each uninterrupted CoreAudio run, and every counter that must not move
is checked. No retry, no restart, no reset. --execute opens audio.

Written 2026-09-11 for the meter-tap bridge; the arm is 'direct' (no preset).
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate import HARNESS, fields, issues, snapshot  # noqa: E402

CONTINUOUS = ['continuous', '--other-channel-load-amplitude', '0.1']
LATENCY = ['measure', '--impulses', '800', '--input-channel', '1', '--output-channel', '1',
           '--maximum-lag-ms', '200', '--other-channel-load-amplitude', '0.1']
REQUIRED = list(range(1, 17))


def run_phase(name, plan, output, host, timeout):
    output.mkdir(parents=True, exist_ok=False)
    summary = {'phase': name, 'passed': False, 'runs': []}
    try:
        for index, command in enumerate(plan, 1):
            before = snapshot(host)
            (output / f'{index}-before.json').write_text(json.dumps(before, indent=2) + '\n')
            if before['ActiveState'] != 'active' or 'stable for' not in before['stage']:
                raise ValueError('service is not stable')
            if index == 1 and name == 'preflight':
                counters = fields(before['bridge'])
                if before['recovers'] != 0 or any(counters.get(k) != '0' for k in (
                        'tx_restarts', 'rx_restarts', 'tx_dropped', 'rx_dropped', 'tx_clip', 'rx_clip',
                        'tx_qlow', 'rx_qlow', 'pitch_errors')):
                    raise ValueError('process already has recoveries, drops, clipping or low-queue events')
                if 'ALIGN status=ok' not in before['log']:
                    raise ValueError('aligned startup was not confirmed')
                if 'DSP loaded ' in before['log']:
                    raise ValueError('direct arm unexpectedly loaded DSP')
            result_path = output.resolve() / f'{index}-audio.json'
            start = time.monotonic()
            with (output / f'{index}-harness.log').open('w') as log:
                outcome = subprocess.run([str(HARNESS), *command, '--device', 'USB 16x16',
                                          '--buffer-frames', '64', '--output', str(result_path)],
                                         stdout=log, stderr=log, timeout=timeout)
            after = snapshot(host)
            (output / f'{index}-after.json').write_text(json.dumps(after, indent=2) + '\n')
            if outcome.returncode != 0:
                raise ValueError('harness failed; no retry')
            report = json.loads(result_path.read_text())
            errors = issues(before, after, report, 'direct', REQUIRED)
            if name == 'latency' and summary['runs']:
                previous = summary['runs'][0]['latency']['medianSamples']
                if report['correlation']['statistics']['medianSamples'] != previous:
                    errors.append('latency differs from the first run of this session')
            b, a = fields(before['bridge']), fields(after['bridge'])
            run = {'index': index, 'seconds': round(time.monotonic() - start, 1), 'errors': errors,
                   'bridgeBefore': {k: b.get(k) for k in ('tx_qfloor', 'rx_qfloor', 'meter_us_max', 'meter_us_mean', 'tx_pullmax', 'tx_gapmax_us', 'rx_gapmax_us')},
                   'bridgeAfter': {k: a.get(k) for k in ('tx_qfloor', 'rx_qfloor', 'meter_us_max', 'meter_us_mean', 'tx_pullmax', 'tx_gapmax_us', 'rx_gapmax_us')},
                   'lead': [s.get('sink_min_time') for s in after['lead']]}
            if name == 'latency':
                stats = report['correlation']['statistics']
                run['latency'] = {'medianSamples': stats.get('medianSamples'), 'min': stats.get('minimumSamples'),
                                  'max': stats.get('maximumSamples'), 'medianMs': stats.get('medianMilliseconds'),
                                  'count': stats.get('count'), 'peak': report.get('capturedPeak')}
            else:
                run['channels'] = [{'peak': c['peak'], 'longestZeroRun': c['longestZeroRun']} for c in report['channels']]
            summary['runs'].append(run)
            print(json.dumps(run), flush=True)
            if errors:
                raise ValueError('; '.join(errors))
        summary['passed'] = True
    except Exception as error:  # record and stop; never retry
        summary['error'] = str(error)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'{name}: {"PASS" if summary["passed"] else "FAIL: " + summary.get("error", "")}', flush=True)
    return summary['passed']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--host', default='bdimaio@192.168.1.201')
    parser.add_argument('--phases', default='preflight,latency,soak')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    plans = {'preflight': ('preflight', [CONTINUOUS + ['--seconds', '60']], 260),
             'latency': ('latency', [LATENCY] * 4, 260),
             'soak': ('soak', [CONTINUOUS + ['--seconds', '600']], 650)}
    phases = [plans[p] for p in args.phases.split(',')]
    print(json.dumps({'harness': str(HARNESS), 'phases': [(n, p) for n, p, _ in phases], 'execute': args.execute}, indent=1))
    if not args.execute:
        return 0
    for name, plan, timeout in phases:
        if not run_phase(name, plan, args.output / name, args.host, timeout):
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
