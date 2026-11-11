#!/usr/bin/env python3
"""Build an immutable, inspectable deployment bundle; never contacts the Pi."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
DIRECT = '05f37bd911c4f9960eb6f2150accc8603dc4ac92e26622a397706619eea7a233'
DSP = '406699bd4cf5763defb3560dca3d447d1dd2e8928dc370a643f1a080be026c88'
PRESETS = {
    'transparent': 'ad69598473691bffdd0808d79d4ff37f4d46ef9f0fa2b34b5fa1f3152b9bbeb9',
    'loaded': '2b6baa0484a7d9a7d7a39f189d772a6864a473163c6e8098723954b652bb456c',
}
DESTINATIONS = {'bridge': '/usr/local/libexec/usb16x16-rt-bridge',
                'supervisor': '/usr/local/sbin/usb16x16-aes67-supervisor',
                'aes67.conf': '/etc/usb16x16/aes67.conf'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def make_conf(text):
    matches = re.findall(r'^PROFILE=([a-z0-9-]+)$', text, re.M)
    if len(matches) != 1:
        raise ValueError('expected exactly one active profile')
    prefix = 'PROFILE_' + matches[0].upper().replace('-', '_') + '_'
    fields = {}
    for line in text.splitlines():
        if line.startswith(prefix):
            key, value = line[len(prefix):].split('=', 1)
            fields[key] = value
    if fields.get('STATUS') != 'accepted' or fields.get('SINK_DELAY') != '103':
        raise ValueError('baseline must be the accepted sd103 profile')
    if any('DSP_' in key for key in fields) or 'PROFILE_DSP_' in text:
        raise ValueError('baseline already carries DSP profiles')
    result = re.sub(r'^PROFILE=.*$', 'PROFILE=dsp-direct', text, flags=re.M).rstrip() + '\n'
    for arm in ('direct', 'transparent', 'loaded'):
        block = dict(fields)
        block.update(STATUS='experimental', COVER='"not accepted"', MEASURED='"not measured"',
                     DESCRIPTION=f'"DSP service validation: {arm}; restart required"')
        if arm != 'direct':
            block['DSP_PRESET'] = f'/etc/usb16x16/dsp/{arm}.dsp'
            block['DSP_SHA256'] = PRESETS[arm]
        result += f'\n# Derived from {matches[0]}; transport fields unchanged.\n'
        result += ''.join(f'PROFILE_DSP_{arm.upper()}_{k}={v}\n' for k, v in block.items())
    return result


def prepare(baseline, candidate, transparent, destination):
    if destination.exists():
        raise ValueError('output already exists; choose a new bundle directory')
    accepted = ROOT / 'work/phase4-bridge/artifacts/pi-aarch64/usb16x16-rt-bridge'
    loaded = ROOT / 'outputs/dsp-verify/headtohead-20260910T173732Z/loaded.dsp'
    for path, digest in ((accepted, DIRECT), (candidate, DSP),
                         (transparent, PRESETS['transparent']), (loaded, PRESETS['loaded'])):
        if sha(path) != digest:
            raise ValueError(f'hash mismatch: {path}')
    # The source must be the installed supervisor plus this narrowly scoped change.
    baseline_supervisor = (baseline / 'supervisor').read_text()
    if f'expected_bridge_sha256={DIRECT}' not in baseline_supervisor:
        raise ValueError('baseline supervisor does not pin the accepted bridge')
    supervisor = (ROOT / 'work/aes67-bridge/usb16x16-aes67-supervisor').read_text()
    if supervisor.count(f'expected_bridge_sha256={DIRECT}') != 1:
        raise ValueError('source supervisor bridge pin changed')
    conf = make_conf((baseline / 'aes67.conf').read_text())
    destination.mkdir(parents=True)
    for folder in ('baseline', 'candidate'):
        (destination / folder).mkdir()
    shutil.copyfile(accepted, destination / 'baseline/bridge')
    for name in ('supervisor', 'aes67.conf'):
        shutil.copyfile(baseline / name, destination / 'baseline' / name)
    shutil.copyfile(candidate, destination / 'candidate/bridge')
    (destination / 'candidate/supervisor').write_text(supervisor.replace(
        f'expected_bridge_sha256={DIRECT}', f'expected_bridge_sha256={DSP}'))
    (destination / 'candidate/aes67.conf').write_text(conf)
    for name, path in (('transparent', transparent), ('loaded', loaded)):
        shutil.copyfile(path, destination / 'candidate' / f'{name}.dsp')
    shutil.copyfile(Path(__file__).with_name('deploy.py'), destination / 'deploy.py')
    manifest = {'state': 'prepared-not-installed-not-accepted', 'destinations': DESTINATIONS,
                'files': {str(p.relative_to(destination)): sha(p)
                          for p in sorted(destination.rglob('*')) if p.is_file()}}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--transparent', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.baseline, args.candidate, args.transparent, args.output), indent=2))
