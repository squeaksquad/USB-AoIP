#!/usr/bin/env python3
"""Bounded service validation. Default prints the plan; --execute opens audio.

No readiness retry loop, service restart, remote polling, or latency estimate for
loaded DSP. Reads the Pi only before/after each uninterrupted CoreAudio run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time

from deploy import checked_bundle

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / 'work/latency-harness/.build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency'
REMOTE = r'''
import json, pathlib, subprocess, urllib.request
p = pathlib.Path
props = subprocess.check_output(['systemctl', 'show', 'usb16x16-aes67',
    '-p', 'ActiveState', '-p', 'InvocationID', '-p', 'NRestarts', '-p', 'MainPID'], text=True)
result = dict(line.split('=', 1) for line in props.splitlines())
result['stage'] = p('/run/usb16x16/stage').read_text()
result['bridge'] = p('/run/usb16x16/last-bridge').read_text()
result['recovers'] = len(p('/run/usb16x16/recovers').read_text().splitlines())
result['conf'] = p('/etc/usb16x16/aes67.conf').read_text()
import hashlib
result['hashes'] = {name: hashlib.sha256(p(path).read_bytes()).hexdigest() for name, path in (
    ('bridge', '/usr/local/libexec/usb16x16-rt-bridge'),
    ('supervisor', '/usr/local/sbin/usb16x16-aes67-supervisor'))}
result['boot'] = p('/proc/sys/kernel/random/boot_id').read_text().strip()
pid = subprocess.check_output(['pgrep', '-f', '^/usr/local/libexec/usb16x16-rt-bridge( |$)'], text=True).strip()
result['bridge_identity'] = pid + ':' + p('/proc/' + pid + '/stat').read_text().split(') ', 1)[1].split()[19]
result['log'] = '\n'.join(line for line in p('/run/usb16x16/bridge.log').read_text().splitlines()
                          if line.startswith(('DSP ', 'ALIGN ', 'PRIMED ', 'ALIGN_TRIGGER ')))
result['lead'] = [json.load(urllib.request.urlopen('http://127.0.0.1:8080/api/sink/status/' + str(i),
                                                timeout=4)) for i in (0, 1)]
print(json.dumps(result))
'''


def fields(line):
    return dict(token.split('=', 1) for token in line.split() if '=' in token)


def issues(before, after, report, arm, required, *, zero_run_gate=True):
    errors = []
    for key in ('InvocationID', 'MainPID', 'NRestarts', 'boot', 'bridge_identity'):
        if before[key] != after[key]:
            errors.append(f'service identity/counter changed: {key}')
    if before['conf'] != after['conf'] or before['hashes'] != after['hashes']:
        errors.append('service configuration or binaries changed')
    if after['recovers'] != before['recovers']:
        errors.append('RECOVER count changed (including reset)')
    b, a = fields(before['bridge']), fields(after['bridge'])
    for key in ('tx_restarts', 'rx_restarts', 'tx_dropped', 'rx_dropped', 'tx_clip', 'rx_clip',
                'tx_qlow', 'rx_qlow', 'pitch_errors'):
        if key not in a or key not in b or a[key] != b[key]:
            errors.append(f'bridge counter changed or missing: {key}')
    for key in ('tx_input', 'rx_input'):
        if int(a.get(key, 0)) <= int(b.get(key, 0)):
            errors.append(f'no frame progress: {key}')
    if arm != 'direct' and int(a.get('dsp_calls', 0)) <= int(b.get('dsp_calls', 0)):
        errors.append('DSP processing counter did not advance')
    for key in ('inputDiscontinuities', 'outputDiscontinuities'):
        if report.get(key) != 0:
            errors.append(key)
    if report.get('kind') == 'continuous-activity-not-latency':
        if report['invalidBuffers']:
            errors.append('invalid audio buffers')
        if report.get('invalidTimestamps', 0):
            errors.append('invalid audio timestamps')
        if report['inputFrames'] < report['seconds'] * 48000 - 48000:
            errors.append('insufficient captured frames')
        for channel in required:
            stats = report['channels'][channel - 1]
            if stats['samples'] < (report['seconds'] - 3) * 48000 or stats['peak'] < 1e-8:
                errors.append(f'no sustained return signal on input {channel}')
            if (zero_run_gate and stats['longestZeroRun'] >= 4) or stats['nonFinite'] or stats['fullScaleSamples']:
                errors.append(f'silence run, invalid sample or full scale on input {channel}')
    else:
        if arm == 'loaded':
            errors.append('loaded preset cannot be evaluated with impulse correlation')
        stats = report.get('correlation', {}).get('statistics', {})
        if stats.get('count') != 800 or stats.get('maximumSamples') != stats.get('minimumSamples'):
            errors.append('incomplete or nonconstant impulse result')
        if report.get('capturedPeak', 0) < 0.01:
            errors.append('weak impulse return')
    return errors


def snapshot(host):
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
        '-o', 'HostKeyAlias=audio-dev.local', host, 'python3 -c ' + shlex.quote(REMOTE)],
        check=True, capture_output=True, text=True, timeout=25)
    return json.loads(result.stdout)


def verify_snapshot(state, manifest, arm, expected_conf):
    if state['ActiveState'] != 'active' or not any(s in state['stage'] for s in (' running', ' stable for')):
        raise ValueError('service is not running/stable')
    if state['conf'] != expected_conf:
        raise ValueError('live configuration does not match the packaged arm')
    counters = fields(state['bridge'])
    if state['recovers'] != 0 or any(counters.get(key) != '0' for key in (
            'tx_restarts', 'rx_restarts', 'tx_dropped', 'rx_dropped',
            'tx_clip', 'rx_clip', 'tx_qlow', 'rx_qlow', 'pitch_errors')):
        raise ValueError('process already has recoveries, drops, clipping or low-queue events')
    for key in ('bridge', 'supervisor'):
        if state['hashes'][key] != manifest['files']['candidate/' + key]:
            raise ValueError(f'live {key} differs from bundle')
    if arm != 'direct':
        if 'DSP loaded ' not in state['log'] or 'DSP engaged' not in state['log']:
            raise ValueError('DSP loaded/engaged markers missing')
        if f'/etc/usb16x16/dsp/{arm}.dsp' not in state['log']:
            raise ValueError('loaded DSP path does not match arm')
    elif 'DSP loaded ' in state['log']:
        raise ValueError('direct arm unexpectedly loaded DSP')
    if 'ALIGN status=ok' not in state['log']:
        raise ValueError('aligned startup was not confirmed')
    for sink in state['lead']:
        if sink.get('sink_min_time', -1) <= 0:
            raise ValueError('missing, zero or negative packet arrival lead')


def execute(args):
    manifest = checked_bundle(args.bundle)
    criterion = {'id': 'legacy'}
    if getattr(args, 'signal_criterion', 'legacy') == 'reference-events-v1':
        if args.arm != 'loaded':
            raise ValueError('reference event criterion is loaded-only')
        if sorted(args.required_inputs) != list(range(1, 17)):
            raise ValueError('reference event criterion requires all 16 returns')
        from reference_check import analyze, criterion_identity, explains_zero_gate
        criterion = criterion_identity(manifest)
    if args.phase == 'capture' and args.arm != 'loaded':
        raise ValueError('targeted event capture is loaded-only')
    continuous = ['continuous', '--seconds', str({'soak': 600, 'capture': 90}.get(args.phase, 60)),
                  '--other-channel-load-amplitude', '0.1']
    latency = ['measure', '--impulses', '800', '--input-channel', '1', '--output-channel', '1',
               '--maximum-lag-ms', '200', '--other-channel-load-amplitude', '0.1']
    if args.arm == 'loaded' and args.phase == 'latency':
        raise ValueError('loaded is stability-only; use --phase preflight or soak')
    plan = [latency] * 4 if args.phase == 'latency' else [continuous]
    print(json.dumps({'arm': args.arm, 'phase': args.phase, 'commands': plan,
                      'requiredInputs': args.required_inputs, 'signalCriterion': criterion,
                      'execute': args.execute}, indent=2), flush=True)
    if not args.execute:
        return
    args.output.mkdir(parents=True, exist_ok=False)
    # Reuse only a preflight from this bundle, arm, harness and return-channel set.
    harness_hash = hashlib.sha256(HARNESS.read_bytes()).hexdigest()
    bundle_hash = hashlib.sha256((args.bundle / 'manifest.json').read_bytes()).hexdigest()
    if args.phase != 'preflight':
        if not args.preflight:
            raise ValueError('a passed --preflight summary.json is required')
        proof = json.loads(args.preflight.read_text())
        if not (proof.get('passed') and proof.get('phase') == 'preflight' and
                proof.get('arm') == args.arm and proof.get('bundle') == bundle_hash and
                proof.get('harness') == harness_hash and proof.get('requiredInputs') == args.required_inputs):
            raise ValueError('preflight does not match this run')
        if proof.get('signalCriterion', {'id': 'legacy'}) != criterion:
            raise ValueError('preflight signal criterion differs; obtain a new preflight')
    expected_conf = (args.bundle / 'candidate/aes67.conf').read_text().replace(
        'PROFILE=dsp-direct\n', f'PROFILE=dsp-{args.arm}\n', 1)
    summary = {'phase': args.phase, 'arm': args.arm, 'bundle': bundle_hash, 'harness': harness_hash,
               'requiredInputs': args.required_inputs, 'signalCriterion': criterion, 'passed': False, 'runs': [],
               'acceptance': 'not established; manual RTL and final review still required'}
    if args.phase == 'capture':
        summary['acceptance'] = 'diagnostic event capture only; existing zero-run gate unchanged'
    try:
        for index, command in enumerate(plan, 1):
            before = snapshot(args.host)
            (args.output / f'{index}-before.json').write_text(json.dumps(before, indent=2) + '\n')
            verify_snapshot(before, manifest, args.arm, expected_conf)
            if args.phase != 'preflight' and before['InvocationID'] != proof['invocation']:
                raise ValueError('service restarted after preflight; run a new preflight')
            if args.phase != 'preflight' and before['bridge_identity'] != proof['bridge_identity']:
                raise ValueError('bridge restarted after preflight; run a new preflight')
            result_path = args.output.resolve() / f'{index}-audio.json'
            start = time.monotonic()
            with (args.output / f'{index}-harness.log').open('w') as log:
                outcome = subprocess.run([str(HARNESS), *command, '--device', 'USB-AoIP',
                    '--buffer-frames', '64', '--output', str(result_path)], stdout=log, stderr=log,
                    timeout=650 if args.phase == 'soak' else 260)
            # No SSH or transfers took place while CoreAudio was running.
            after = snapshot(args.host)
            (args.output / f'{index}-after.json').write_text(json.dumps(after, indent=2) + '\n')
            verify_snapshot(after, manifest, args.arm, expected_conf)
            if outcome.returncode != 0:
                raise ValueError('harness failed; no retry')
            report = json.loads(result_path.read_text())
            if args.phase == 'capture' and report.get('eventCapture', {}).get('version') != 1:
                raise ValueError('harness did not provide event capture evidence')
            reference = None
            explained = False
            if criterion['id'] != 'legacy':
                # Loaded phases have exactly one run. Analyze saved evidence
                # only after audio closes; never generate reference on the IO path.
                reference = analyze(args.output, args.bundle, args.output / 'reference')
                explained = explains_zero_gate(reference, report)
            errors = issues(before, after, report, args.arm, args.required_inputs, zero_run_gate=not explained)
            if reference is not None and not explained:
                errors.append('reference event check did not clear the signal gate: ' + reference.get('reason', reference['status']))
            if args.phase == 'latency' and summary['runs']:
                previous = summary['runs'][0]['latency']['medianSamples']
                if report['correlation']['statistics']['medianSamples'] != previous:
                    errors.append('latency level changed between runs on this arm')
            metrics = fields(after['bridge'])
            summary['runs'].append({'seconds': round(time.monotonic() - start, 2), 'errors': errors,
                'metrics': {k: v for k, v in metrics.items() if k in
                    ('tx_qfloor', 'rx_qfloor', 'tx_gapmax_us', 'rx_gapmax_us', 'dsp_us_max', 'dsp_us_mean')},
                'latency': report.get('correlation', {}).get('statistics'),
                'reference': None if reference is None else {k: reference.get(k) for k in
                    ('status', 'evidenceComplete', 'coveredInputFrames', 'wholeRunValidated', 'legacyGateErrors')}})
            summary['invocation'] = after['InvocationID']
            summary['bridge_identity'] = after['bridge_identity']
            if errors:
                raise ValueError('; '.join(errors))
            print(f'run {index}/{len(plan)} passed', flush=True)
        summary['passed'] = True
    except Exception as error:
        summary['error'] = str(error)
        raise
    finally:
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--arm', choices=('direct', 'transparent', 'loaded'), required=True)
    parser.add_argument('--phase', choices=('preflight', 'latency', 'soak', 'capture'), default='preflight')
    parser.add_argument('--required-inputs', type=lambda s: [int(n) for n in s.split(',')], required=True,
                        help='physically patched return inputs, e.g. 1,2; use 1..16 only if all return')
    parser.add_argument('--host', default='bdimaio@192.168.1.201')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--preflight', type=Path)
    parser.add_argument('--signal-criterion', choices=('legacy', 'reference-events-v1'), default='legacy',
                        help='opt-in loaded activity criterion; does not verify unsaved samples')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    if not args.required_inputs or any(n < 1 or n > 16 for n in args.required_inputs):
        parser.error('required inputs must be 1..16')
    try:
        execute(args)
    except Exception as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
