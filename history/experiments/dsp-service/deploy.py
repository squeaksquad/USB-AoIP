#!/usr/bin/env python3
"""Pi-side bundle check/install/rollback. Never starts, stops or enables audio."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

DESTINATIONS = {'bridge': '/usr/local/libexec/usb16x16-rt-bridge',
                'supervisor': '/usr/local/sbin/usb16x16-aes67-supervisor',
                'aes67.conf': '/etc/usb16x16/aes67.conf'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked_bundle(bundle):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    expected = {f'{side}/{name}' for side in ('baseline', 'candidate') for name in DESTINATIONS}
    expected |= {'candidate/transparent.dsp', 'candidate/loaded.dsp', 'deploy.py'}
    if set(manifest['files']) != expected or manifest['destinations'] != DESTINATIONS:
        raise ValueError('unexpected manifest paths')
    for name, sha in manifest['files'].items():
        if (bundle / name).is_symlink() or digest((bundle / name).read_bytes()) != sha:
            raise ValueError(f'bundle hash mismatch: {name}')
    return manifest


def normalized_conf(data):
    text = data.decode()
    selections = re.findall(r'^PROFILE=(.*)$', text, re.M)
    if len(selections) != 1 or selections[0] not in ('dsp-direct', 'dsp-transparent', 'dsp-loaded'):
        raise ValueError('unexpected DSP profile selection')
    return re.sub(r'^PROFILE=.*$', 'PROFILE=dsp-direct', text, flags=re.M)


def atomic_write(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix='.dsp-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply_transaction(changes):
    previous = {path: (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists()
                else (None, mode) for path, (data, mode) in changes.items()}
    try:
        for path, (data, mode) in changes.items():
            if data is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, data, mode)
    except BaseException:
        for path, (data, mode) in previous.items():
            if data is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, data, mode)
        raise


def run(bundle, action):
    manifest = checked_bundle(bundle)
    if action == 'check':
        print(json.dumps(manifest, indent=2))
        return
    if os.geteuid() != 0:
        raise ValueError('run install/rollback with sudo')
    state = subprocess.run(['systemctl', 'show', '-p', 'ActiveState', '--value',
                            'usb16x16-aes67'], check=True, capture_output=True, text=True).stdout.strip()
    if state != 'inactive':
        raise ValueError('AES67 service must be stopped and inactive first')
    # Unit inactivity alone does not exclude a manually launched candidate.
    if Path('/tmp/usb16x16-phase4-candidate.ready').exists():
        raise ValueError('candidate ready marker present')
    for pattern in (r'(^|/)usb16x16-rt-bridge( |$)', r'(^|/)aes67-daemon( |$)'):
        probe = subprocess.run(['pgrep', '-f', pattern], capture_output=True)
        if probe.returncode != 1:
            raise ValueError('foreign audio process present, or process check failed')
    source_side = 'candidate' if action == 'install' else 'baseline'
    expected_side = 'baseline' if action == 'install' else 'candidate'
    for name, target in DESTINATIONS.items():
        path = Path(target)
        info = path.lstat()
        mode = 0o644 if name == 'aes67.conf' else 0o755
        if path.is_symlink() or info.st_uid != 0 or info.st_gid != 0 or info.st_mode & 0o777 != mode:
            raise ValueError(f'installed file ownership mismatch: {path}')
        data = path.read_bytes()
        expected = (bundle / expected_side / name).read_bytes()
        if name == 'aes67.conf' and action == 'rollback':
            equal = normalized_conf(data) == normalized_conf(expected)
        else:
            equal = data == expected
        if not equal:
            raise ValueError(f'installed file changed since bundle preparation: {path}')
    preset_dir = Path('/etc/usb16x16/dsp')
    if preset_dir.is_symlink():
        raise ValueError('DSP directory is a symlink')
    if preset_dir.exists() and (preset_dir.stat().st_uid != 0 or preset_dir.stat().st_gid != 0 or
                                preset_dir.stat().st_mode & 0o777 != 0o755):
        raise ValueError('DSP directory ownership mismatch')
    preset_dir.mkdir(mode=0o755, exist_ok=True)
    for arm in ('transparent', 'loaded'):
        path = preset_dir / f'{arm}.dsp'
        if action == 'install' and (path.exists() or path.is_symlink()):
            raise ValueError(f'preset path already exists: {path}')
        if action == 'rollback' and (path.is_symlink() or not path.is_file() or
                digest(path.read_bytes()) != manifest['files'][f'candidate/{arm}.dsp']):
            raise ValueError(f'preset changed: {path}')
    subprocess.run(['bash', '-n', str(bundle / source_side / 'supervisor')], check=True)
    changes = {preset_dir / f'{arm}.dsp': ((bundle / 'candidate' / f'{arm}.dsp').read_bytes()
               if action == 'install' else None, 0o644) for arm in ('transparent', 'loaded')}
    changes.update({Path(target): ((bundle / source_side / name).read_bytes(),
                    0o644 if name == 'aes67.conf' else 0o755) for name, target in DESTINATIONS.items()})
    apply_transaction(changes)
    print(f'{action} complete; service remains stopped. USB gadget, unit and sudoers unchanged.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'install', 'rollback'))
    args = parser.parse_args()
    run(Path(__file__).resolve().parent, args.action)
