#!/usr/bin/env python3
"""One authorized loaded preflight/soak with a frozen criterion; restore direct."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'work/dsp-service'))
from accept import remote, SSH
from deploy import checked_bundle
from reference_check import criterion_identity
from validate import HARNESS, execute, snapshot, verify_snapshot


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def select(arm):
    remote('sudo -n systemctl stop usb16x16-aes67')
    remote('sudo -n /usr/local/sbin/usb16x16-aes67-supervisor switch-profile dsp-' + arm)
    remote('sudo -n systemctl start usb16x16-aes67')
    deadline = time.monotonic() + 210
    while time.monotonic() < deadline:
        if 'stable for' in remote('cat /run/usb16x16/stage'):
            return
        time.sleep(10)
    raise RuntimeError('service did not settle within 210 seconds')


def main():
    if any((OUT / name).exists() for name in ('preflight', 'soak', 'initial-state.json')):
        raise RuntimeError('existing evidence; no overwrite or automatic retry')
    bundle = ROOT / 'outputs/dsp-service/review-20260911'
    frozen = json.loads((ROOT / 'outputs/dsp-service/reference-check-20260911/verification.json').read_text())
    for path, expected in frozen['sourceHashes'].items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != expected:
            raise RuntimeError('frozen source changed: ' + path)
    if hashlib.sha256(HARNESS.read_bytes()).hexdigest() != 'edae7bdb99b28abfb151ee1eeae644542f8e4309785b0e62eb8ef4beae1b9361':
        raise RuntimeError('signed harness changed')
    manifest = checked_bundle(bundle)
    criterion = criterion_identity(manifest)
    if criterion != frozen['criterion']:
        raise RuntimeError('frozen criterion changed')
    save('frozen-verification.json', frozen)
    direct = (bundle / 'candidate/aes67.conf').read_text()
    initial = snapshot('bdimaio@192.168.1.201')
    save('initial-state.json', initial)
    verify_snapshot(initial, manifest, 'direct', direct)
    summary = {'classification': 'prospective-loaded-activity-and-stability',
               'signalCriterion': criterion, 'preflight': 'not-run', 'soak': 'not-run',
               'restoration': 'pending', 'wholeRunValidated': False}
    try:
        print('Selecting loaded DSP; waiting for stable service.', flush=True)
        select('loaded')
        for phase in ('preflight', 'soak'):
            summary[phase] = 'running'
            save('run-status.json', summary)
            print(f'Starting {phase}; no Pi polling during audio.', flush=True)
            try:
                execute(SimpleNamespace(bundle=bundle, arm='loaded', phase=phase,
                    required_inputs=list(range(1, 17)), host='bdimaio@192.168.1.201',
                    output=OUT / phase, preflight=OUT / 'preflight/summary.json',
                    signal_criterion='reference-events-v1', execute=True))
                summary[phase] = 'passed-reference-events-v1'
            except Exception as error:
                summary[phase] = 'failed-gate-or-run-error'
                summary['error'] = str(error)
                raise
            finally:
                # CoreAudio has closed; retain queue history even on failure.
                with (OUT / f'{phase}-bridge.txt').open('w') as stream:
                    subprocess.run(SSH + ['cat /run/usb16x16/bridge.log'], check=True,
                        stdout=stream, stderr=subprocess.PIPE, text=True, timeout=25)
                save('run-status.json', summary)
    except Exception as error:
        summary['error'] = str(error)
        print(f'Run stopped: {error}', flush=True)
    finally:
        print('Restoring direct mode.', flush=True)
        try:
            select('direct')
            final = snapshot('bdimaio@192.168.1.201')
            save('final-state.json', final)
            verify_snapshot(final, manifest, 'direct', direct)
            summary['restoration'] = 'direct-verified'
            print('Direct mode restored and verified.', flush=True)
        except Exception as error:
            summary['restoration'] = 'FAILED'
            summary['restorationError'] = str(error)
            raise
        finally:
            save('run-status.json', summary)


if __name__ == '__main__':
    main()
