#!/usr/bin/env python3
"""One authorized loaded diagnostic run; restore direct even on test failure."""
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
from validate import execute, snapshot, verify_snapshot


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + '\n')


def settle():
    deadline = time.monotonic() + 210
    while time.monotonic() < deadline:
        if 'stable for' in remote('cat /run/usb16x16/stage'):
            return
        time.sleep(10)
    raise RuntimeError('service did not settle within 210 seconds')


def select(arm):
    remote('sudo -n systemctl stop usb16x16-aes67')
    remote('sudo -n /usr/local/sbin/usb16x16-aes67-supervisor switch-profile dsp-' + arm)
    remote('sudo -n systemctl start usb16x16-aes67')
    settle()


def main():
    if any((OUT / name).exists() for name in ('preflight', 'capture', 'initial-state.json')):
        raise RuntimeError('existing run evidence; no overwrite or automatic retry')
    bundle = ROOT / 'outputs/dsp-service/review-20260911'
    build = json.loads((OUT / 'build-verification.json').read_text())
    for path, expected in build['sourceAndBinaryHashes'].items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != expected:
            raise RuntimeError('capture build changed: ' + path)
    manifest = checked_bundle(bundle)
    direct = (bundle / 'candidate/aes67.conf').read_text()
    initial = snapshot('bdimaio@192.168.1.201')
    save('initial-state.json', initial)
    verify_snapshot(initial, manifest, 'direct', direct)
    summary = {'classification': 'diagnostic-only', 'preflight': 'not-run', 'capture': 'not-run',
               'restoration': 'pending', 'gate': 'unchanged'}
    try:
        print('Selecting loaded DSP; waiting for stable service.', flush=True)
        select('loaded')
        for phase in ('preflight', 'capture'):
            summary[phase] = 'running'
            save('run-status.json', summary)
            print(f'Starting {phase}; no Pi polling during audio.', flush=True)
            try:
                execute(SimpleNamespace(bundle=bundle, arm='loaded', phase=phase,
                    required_inputs=list(range(1, 17)), host='bdimaio@192.168.1.201',
                    output=OUT / phase, preflight=OUT / 'preflight/summary.json', execute=True))
                summary[phase] = 'passed-existing-gate'
            except Exception as error:
                summary[phase] = 'failed-existing-gate-or-run-error'
                summary['error'] = str(error)
                raise
            finally:
                # Audio has closed; retain queue history even on gate failure.
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
