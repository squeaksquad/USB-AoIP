import copy
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import deploy
import prepare
import validate

ROOT = prepare.ROOT
BUNDLE = ROOT / 'outputs/dsp-service/review-20260911'


def function(text, name):
    return re.search(r'^' + name + r'\(\) \{.*?^\}', text, re.M | re.S)[0]


class DSPServiceTests(unittest.TestCase):
    def test_profiles_preserve_transport_and_are_experimental(self):
        text = (BUNDLE / 'baseline/aes67.conf').read_text()
        made = prepare.make_conf(text)
        selected = re.search(r'^PROFILE=(.*)$', text, re.M)[1].upper().replace('-', '_')
        fields = dict(re.findall(r'^PROFILE_' + selected + r'_([^=]+)=(.*)$', text, re.M))
        for arm in ('DIRECT', 'TRANSPARENT', 'LOADED'):
            result = dict(re.findall(r'^PROFILE_DSP_' + arm + r'_([^=]+)=(.*)$', made, re.M))
            for key, value in fields.items():
                if key not in ('STATUS', 'COVER', 'MEASURED', 'DESCRIPTION'):
                    self.assertEqual(result[key], value)
            self.assertEqual(result['STATUS'], 'experimental')
        self.assertNotIn('PROFILE_DSP_DIRECT_DSP_PRESET', made)

    def test_bundle_tampering_is_rejected(self):
        deploy.checked_bundle(BUNDLE)
        with tempfile.TemporaryDirectory() as directory:
            import shutil
            dest = Path(directory) / 'bundle'
            shutil.copytree(BUNDLE, dest)
            (dest / 'candidate/loaded.dsp').write_text('wrong preset')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                deploy.checked_bundle(dest)

    def test_rollback_permits_only_profile_selection_change(self):
        conf = (BUNDLE / 'candidate/aes67.conf').read_bytes()
        changed = conf.replace(b'PROFILE=dsp-direct\n', b'PROFILE=dsp-loaded\n', 1)
        self.assertEqual(deploy.normalized_conf(conf), deploy.normalized_conf(changed))
        with self.assertRaises(ValueError):
            deploy.normalized_conf(conf.replace(b'PROFILE=dsp-direct\n', b'PROFILE=unknown\n', 1))
        self.assertNotEqual(deploy.normalized_conf(conf), deploy.normalized_conf(changed + b'# operator edit\n'))

    def test_failed_install_restores_previous_files_and_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / 'bridge', Path(directory) / 'preset'
            a.write_bytes(b'accepted'); a.chmod(0o755)
            real_write = deploy.atomic_write
            calls = 0

            def failing_write(path, data, mode):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError('simulated disk failure')
                real_write(path, data, mode)

            with patch.object(deploy, 'atomic_write', failing_write):
                with self.assertRaises(OSError):
                    deploy.apply_transaction({a: (b'candidate', 0o644), b: (b'preset', 0o644)})
            self.assertEqual(a.read_bytes(), b'accepted')
            self.assertEqual(a.stat().st_mode & 0o777, 0o755)
            self.assertFalse(b.exists())

    def shell_dsp(self, preset='', digest='', verify=False, bridge=prepare.DSP, owner='root:root:644', actual=None):
        text = (ROOT / 'work/aes67-bridge/usb16x16-aes67-supervisor').read_text()
        script = 'set -euo pipefail\nsay() { echo "$*"; }\n'
        script += 'p() { case "$1" in DSP_PRESET) echo ' + shlex.quote(preset) + ';; DSP_SHA256) echo ' + shlex.quote(digest) + ';; esac; }\n'
        script += 'expected_bridge_sha256=' + bridge + '\n'
        script += 'stat() { case "${@: -1}" in *.dsp) echo ' + shlex.quote(owner) + ';; *) echo root:root:755;; esac; }\n'
        script += 'sha256_of() { echo ' + shlex.quote(actual or digest) + '; }\n'
        script += function(text, 'validate_dsp_profile') + '\n'
        # Mock only file existence predicates for the fixed root-owned preset.
        check = function(text, 'verify_dsp_artifact').replace('[ -f "$preset" ]', 'true')
        script += check + '\n' + ('verify_dsp_artifact' if verify else 'validate_dsp_profile')
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True).returncode

    def test_preset_rejections_and_direct_bypass(self):
        sha = prepare.PRESETS['loaded']
        preset = '/etc/usb16x16/dsp/loaded.dsp'
        self.assertEqual(self.shell_dsp(verify=True, bridge=prepare.DIRECT), 0)
        self.assertEqual(self.shell_dsp(preset, sha, verify=True), 0)
        for path, digest in (('/tmp/loaded.dsp', sha), (preset, ''), ('', sha), (preset, 'bad')):
            self.assertNotEqual(self.shell_dsp(path, digest), 0)
        self.assertNotEqual(self.shell_dsp(preset, sha, verify=True, bridge=prepare.DIRECT), 0)
        self.assertNotEqual(self.shell_dsp(preset, sha, verify=True, owner='bdimaio:staff:644'), 0)
        self.assertNotEqual(self.shell_dsp(preset, sha, verify=True, actual='0' * 64), 0)

    def test_direct_bridge_arguments_unchanged(self):
        current = (ROOT / 'work/aes67-bridge/usb16x16-aes67-supervisor').read_text()
        previous = (BUNDLE / 'baseline/supervisor').read_text()
        helpers = current[current.index('# p FIELD'):current.index('profile_names()')]
        # The same deterministic profile values exercise both versions' argument builders.
        helpers += '\np() { case "$1" in DSP_PRESET) printf "%s" "${PRESET:-}";; *) printf 0;; esac; }\n'
        def args(source, preset=''):
            script = 'PRESET=' + shlex.quote(preset) + '\n' + helpers + '\n' + function(source, 'bridge_arguments') + '\nbridge_arguments\n'
            return subprocess.check_output(['bash', '-c', script], text=True).splitlines()
        self.assertEqual(args(current), args(previous))
        self.assertEqual(args(current, '/etc/usb16x16/dsp/loaded.dsp'),
                         args(previous) + ['--dsp-preset', '/etc/usb16x16/dsp/loaded.dsp'])

    def fixture(self):
        counters = ('tx_restarts=0 rx_restarts=0 tx_dropped=0 rx_dropped=0 tx_clip=0 rx_clip=0 '
                    'tx_qlow=0 rx_qlow=0 pitch_errors=0 ')
        before = dict(InvocationID='one', MainPID='10', NRestarts='0', boot='a', bridge_identity='b',
                      conf='same', hashes={}, recovers=0, bridge=counters + 'tx_input=100 rx_input=100 dsp_calls=1')
        after = dict(before, bridge=counters + 'tx_input=200 rx_input=200 dsp_calls=2')
        report = dict(kind='continuous-activity-not-latency', inputDiscontinuities=0,
                      outputDiscontinuities=0, invalidBuffers=0, seconds=60, inputFrames=2880000,
                      channels=[dict(samples=2784000, peak=0.1, longestZeroRun=0, nonFinite=0, fullScaleSamples=0)
                                for _ in range(16)])
        return before, after, report

    def test_loaded_signal_checks_do_not_use_correlation(self):
        before, after, report = self.fixture()
        self.assertEqual(validate.issues(before, after, report, 'loaded', [1, 2]), [])
        report['channels'][1]['longestZeroRun'] = 41
        self.assertTrue(validate.issues(before, after, report, 'loaded', [1, 2]))
        report['channels'][1]['longestZeroRun'] = 0
        report['channels'][0]['peak'] = 0
        self.assertTrue(validate.issues(before, after, report, 'loaded', [1, 2]))

    def test_recovery_or_counter_reset_invalidates_run(self):
        before, after, report = self.fixture()
        for field, value in [('recovers', 1), ('bridge_identity', 'different'), ('InvocationID', 'two')]:
            broken = dict(after, **{field: value})
            self.assertTrue(validate.issues(before, broken, report, 'loaded', [1]))
        reset = dict(after, bridge=after['bridge'].replace('tx_input=200', 'tx_input=0'))
        self.assertTrue(validate.issues(before, reset, report, 'loaded', [1]))

    def test_invalid_timestamps_fail_without_relaxing_zero_gate(self):
        before, after, report = self.fixture()
        report['invalidTimestamps'] = 1
        self.assertIn('invalid audio timestamps', validate.issues(before, after, report, 'loaded', [4]))
        report['invalidTimestamps'] = 0
        report['channels'][3]['longestZeroRun'] = 7
        report['eventCapture'] = {'version': 1, 'events': [{'zeroFrames': 7}]}
        self.assertTrue(validate.issues(before, after, report, 'loaded', [4]))
        self.assertEqual(validate.issues(before, after, report, 'loaded', [4], zero_run_gate=False), [])
        report['channels'][3]['nonFinite'] = 1
        self.assertTrue(validate.issues(before, after, report, 'loaded', [4], zero_run_gate=False))

    def test_targeted_capture_plan_is_one_loaded_90_second_run(self):
        from types import SimpleNamespace
        import contextlib
        import io
        args = SimpleNamespace(bundle=BUNDLE, phase='capture', arm='loaded',
                               required_inputs=list(range(1, 17)), execute=False)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            validate.execute(args)
        plan = json.loads(output.getvalue())
        self.assertEqual(len(plan['commands']), 1)
        self.assertEqual(plan['commands'][0][:3], ['continuous', '--seconds', '90'])
        args.arm = 'transparent'
        with self.assertRaisesRegex(ValueError, 'loaded-only'):
            validate.execute(args)

    def test_reference_criterion_is_explicit_loaded_all_channel_and_receipt_bound(self):
        from types import SimpleNamespace
        import contextlib
        import hashlib
        import io
        args = SimpleNamespace(bundle=BUNDLE, phase='soak', arm='loaded',
            required_inputs=list(range(1, 17)), execute=False, signal_criterion='reference-events-v1')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            validate.execute(args)
        identity = json.loads(output.getvalue())['signalCriterion']
        self.assertEqual(identity['id'], 'loaded-event-reference-v1')
        self.assertEqual(len(identity['sha256']), 64)
        args.arm = 'direct'
        with self.assertRaisesRegex(ValueError, 'loaded-only'):
            validate.execute(args)
        args.arm = 'loaded'; args.required_inputs = [1, 2]
        with self.assertRaisesRegex(ValueError, 'all 16'):
            validate.execute(args)
        args.required_inputs = list(range(1, 17)); args.execute = True
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = root / 'harness'; harness.write_bytes(b'test')
            proof = dict(passed=True, phase='preflight', arm='loaded', requiredInputs=args.required_inputs,
                bundle=hashlib.sha256((BUNDLE / 'manifest.json').read_bytes()).hexdigest(),
                harness=hashlib.sha256(harness.read_bytes()).hexdigest())
            args.preflight = root / 'preflight.json'
            args.preflight.write_text(json.dumps(proof))
            args.output = root / 'new-soak'
            with patch.object(validate, 'HARNESS', harness), patch.object(validate, 'snapshot') as snapshot:
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'criterion differs'):
                    validate.execute(args)
                snapshot.assert_not_called()

    def test_preflight_rejects_dirty_process_and_missing_packet_lead(self):
        manifest = deploy.checked_bundle(BUNDLE)
        conf = (BUNDLE / 'candidate/aes67.conf').read_text()
        _, state, _ = self.fixture()
        state.update(ActiveState='active', stage='123 stable for 120s', conf=conf,
                     hashes={key: manifest['files']['candidate/' + key] for key in ('bridge', 'supervisor')},
                     log='ALIGN status=ok', lead=[{'sink_min_time': 900}, {'sink_min_time': 910}])
        validate.verify_snapshot(state, manifest, 'direct', conf)
        for broken in (dict(state, recovers=1), dict(state, lead=[{'sink_min_time': -1}]),
                       dict(state, bridge=state['bridge'].replace('tx_qlow=0', 'tx_qlow=1'))):
            with self.assertRaises(ValueError):
                validate.verify_snapshot(broken, manifest, 'direct', conf)

    def test_reference_criterion_controls_only_new_run_gate(self):
        import contextlib
        import hashlib
        import io
        from types import SimpleNamespace
        from reference_check import criterion_identity
        saved = ROOT / 'outputs/dsp-service/event-capture-20260911/capture'
        report = json.loads((saved / '1-audio.json').read_text())
        snapshots = [json.loads((saved / name).read_text()) for name in ('1-before.json', '1-after.json')]
        identity = criterion_identity(deploy.checked_bundle(BUNDLE))
        for matched in (True, False):
            with self.subTest(matched=matched), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); harness = root / 'harness'; harness.write_bytes(b'test')
                proof = dict(passed=True, phase='preflight', arm='loaded', requiredInputs=list(range(1, 17)),
                    bundle=hashlib.sha256((BUNDLE / 'manifest.json').read_bytes()).hexdigest(),
                    harness=hashlib.sha256(harness.read_bytes()).hexdigest(), signalCriterion=identity,
                    invocation=snapshots[0]['InvocationID'], bridge_identity=snapshots[0]['bridge_identity'])
                receipt = root / 'preflight.json'; receipt.write_text(json.dumps(proof))
                args = SimpleNamespace(bundle=BUNDLE, phase='capture', arm='loaded', execute=True,
                    required_inputs=list(range(1, 17)), signal_criterion='reference-events-v1',
                    host='unused', preflight=receipt, output=root / 'run')
                assessment = dict(status='matched-events' if matched else 'mismatch',
                    evidenceComplete=True, transportAndActivity='passed', wholeRunValidated=False,
                    coveredInputFrames=39, legacyGateErrors=['input 4 zero run'])
                def run(command, **kwargs):
                    Path(command[command.index('--output') + 1]).write_text(json.dumps(report))
                    return SimpleNamespace(returncode=0)
                with patch.object(validate, 'HARNESS', harness), patch.object(validate, 'snapshot', side_effect=snapshots), \
                        patch.object(validate.subprocess, 'run', side_effect=run), \
                        patch('reference_check.analyze', return_value=assessment), contextlib.redirect_stdout(io.StringIO()):
                    if matched:
                        validate.execute(args)
                    else:
                        with self.assertRaisesRegex(ValueError, 'reference event check'):
                            validate.execute(args)
                summary = json.loads((args.output / 'summary.json').read_text())
                self.assertEqual(summary['passed'], matched)
                self.assertFalse(summary['runs'][0]['reference']['wholeRunValidated'])
                self.assertEqual(summary['signalCriterion'], identity)


if __name__ == '__main__':
    unittest.main()
