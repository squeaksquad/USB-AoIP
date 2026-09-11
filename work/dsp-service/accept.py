#!/usr/bin/env python3
"""Run one service arm to an RTL checkpoint, reusing the validated gates.

Does not reset USB/coreaudiod, rebuild artifacts, retry failed tests, or run RTL
while the harness owns the device. Start direct on the user's fresh USB anchor.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
from types import SimpleNamespace

from validate import execute, snapshot, verify_snapshot
from deploy import checked_bundle

SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
       '-o', 'HostKeyAlias=audio-dev.local', 'bdimaio@192.168.1.201']
ROOT = Path(__file__).resolve().parents[2]


def remote(command, timeout=60):
    return subprocess.run(SSH + [command], check=True, capture_output=True, text=True, timeout=timeout).stdout


def run_arm(arm, output):
    bundle = ROOT / 'outputs/dsp-service/review-20260911'
    manifest = checked_bundle(bundle)
    expected = (bundle / 'candidate/aes67.conf').read_text().replace(
        'PROFILE=dsp-direct\n', f'PROFILE=dsp-{arm}\n', 1)
    output.mkdir(parents=True, exist_ok=False)
    state = {'arm': arm, 'status': 'starting', 'completed': [], 'fullAcceptance': False}
    def save():
        (output / 'progress.json').write_text(json.dumps(state, indent=2) + '\n')
    save()
    try:
        selected = remote("sed -n 's/^PROFILE=//p' /etc/usb16x16/aes67.conf").strip()
        if selected != 'dsp-' + arm:
            remote('sudo -n systemctl stop usb16x16-aes67')
            remote('sudo -n /usr/local/sbin/usb16x16-aes67-supervisor switch-profile dsp-' + arm)
            remote('sudo -n systemctl start usb16x16-aes67')
        # Bounded startup checks, before any audio test. No retry or reset.
        deadline = time.monotonic() + 210
        while time.monotonic() < deadline:
            stage = remote('cat /run/usb16x16/stage').strip()
            if 'stable for' in stage:
                break
            time.sleep(10)
        else:
            raise RuntimeError('service did not settle within 210 seconds')
        initial = snapshot('bdimaio@192.168.1.201')
        verify_snapshot(initial, manifest, arm, expected)
        (output / 'initial.json').write_text(json.dumps(initial, indent=2) + '\n')
        phases = ['preflight', 'latency', 'soak'] if arm != 'loaded' else ['preflight', 'soak']
        for phase in phases:
            state['status'] = phase
            state['phaseStarted'] = time.time()
            save()
            print(f'{arm}: {phase} started', flush=True)
            execute(SimpleNamespace(bundle=bundle, arm=arm, phase=phase,
                required_inputs=list(range(1, 17)), host='bdimaio@192.168.1.201',
                output=output / phase, preflight=None if phase == 'preflight' else output / 'preflight/summary.json',
                execute=True))
            # Collection is between tests only. Keep the 1 Hz queue history for
            # reserve-drift review, beyond the runner's counter/signal checks.
            with (output / f'{phase}-bridge.txt').open('w') as stream:
                subprocess.run(SSH + ['cat /run/usb16x16/bridge.log'], check=True,
                               stdout=stream, stderr=subprocess.PIPE, text=True, timeout=25)
            state['completed'].append(phase)
            save()
        state['status'] = 'rtl-checkpoint' if arm != 'loaded' else 'automated-tests-passed'
        print(f'{arm}: {state["status"]}; harness closed', flush=True)
    except BaseException as error:
        state['status'] = 'failed'
        state['error'] = str(error)
        # Do not retry or switch arms after a failure. Preserve this process's
        # evidence for review; caller restores direct before returning playback.
        raise
    finally:
        save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arm', choices=('direct', 'transparent', 'loaded'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run_arm(args.arm, args.output.resolve())
