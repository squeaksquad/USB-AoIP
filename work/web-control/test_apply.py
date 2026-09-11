"""Tests for usb16x16-apply: request validation, the operation's state
machine, verification, and rollback, with the Pi stood in by files and a
scripted runner. Run: python3 -m unittest work/web-control/test_apply.py"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("usb16x16_apply", str(HERE / "usb16x16-apply"))
spec = importlib.util.spec_from_loader("usb16x16_apply", loader)
apply_module = importlib.util.module_from_spec(spec)
loader.exec_module(apply_module)

CONF = """PROFILE=dsp-direct
# comment
PROFILE_DSP_DIRECT_STATUS=accepted
PROFILE_DSP_DIRECT_TARGET=48
PROFILE_DSP_DIRECT_DESCRIPTION="no preset"
PROFILE_DSP_LOADED_STATUS=accepted
PROFILE_DSP_LOADED_TARGET=48
PROFILE_DSP_LOADED_DSP_PRESET=/etc/usb16x16/dsp/loaded.dsp
PROFILE_DSP_LOADED_DSP_SHA256=2b6baa04
PROFILE_FAST_STATUS=experimental
PROFILE_FAST_TARGET=128
"""


class FakeRunner:
    """systemctl and the supervisor as a small model of the stack."""

    def __init__(self, env, fail_switch=None, fail_start_for=None, recover_during_settle_for=None,
                 wrong_dsp_for=None, bridge_line_delay=0, never_bridge_line=False):
        self.bridge_line_delay = bridge_line_delay
        self.never_bridge_line = never_bridge_line
        self.ticks_since_start = 0
        self.env = env
        self.clock = time.time()
        self.unit = "active"
        self.calls = []
        self.fail_switch = fail_switch
        self.fail_start_for = fail_start_for
        self.recover_during_settle_for = recover_during_settle_for
        self.wrong_dsp_for = wrong_dsp_for
        self.settle_ticks = 0

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds
        # the bridge's 1 Hz line keeps coming while the stack runs
        self.ticks_since_start += 1
        if self.unit == "active" and not self.never_bridge_line and self.ticks_since_start >= self.bridge_line_delay:
            self.env.touch_bridge(self.clock)
            self.settle_ticks += 1
            live = self.env.live_profile()
            if self.recover_during_settle_for == live and self.settle_ticks > 3:
                self.env.write("recovers", "1 2 3\n")

    def run(self, argv, timeout=60.0):
        self.calls.append(argv)
        if argv[:2] == ["systemctl", "show"]:
            return 0, self.unit
        if argv[:2] == ["systemctl", "stop"]:
            self.unit = "inactive"
            self.env.write("stage", f"{int(self.clock)} stopped\n")
            return 0, ""
        if argv[:2] == ["systemctl", "start"]:
            live = self.env.live_profile()
            if self.fail_start_for == live:
                self.unit = "failed"
                self.env.write("stage", f"{int(self.clock)} failed: daemon API never answered\n")
                return 0, ""
            self.unit = "active"
            self.settle_ticks = 0
            self.ticks_since_start = 0
            self.env.start_stack(live, self.clock, wrong_dsp=(self.wrong_dsp_for == live),
                                 bridge_line=not (self.bridge_line_delay or self.never_bridge_line))
            return 0, ""
        if argv[1] == "switch-profile":
            if self.fail_switch == argv[2]:
                return 1, "profile rejected"
            self.env.set_profile(argv[2])
            return 0, f"PROFILE={argv[2]} written"
        raise AssertionError(f"unexpected command {argv}")


class Env:
    def __init__(self, root):
        self.root = Path(root)
        self.spool = self.root / "spool"
        self.spool.mkdir()
        self.run_dir = self.root / "run"
        self.run_dir.mkdir()
        self.conf = self.root / "aes67.conf"
        self.conf.write_text(CONF)
        self.start_stack("dsp-direct", time.time())

    def write(self, name, text):
        (self.run_dir / name).write_text(text)

    def live_profile(self):
        for line in self.conf.read_text().splitlines():
            if line.startswith("PROFILE="):
                return line[8:]
        return None

    def set_profile(self, name):
        text = self.conf.read_text().replace(f"PROFILE={self.live_profile()}\n", f"PROFILE={name}\n", 1)
        self.conf.write_text(text)

    def start_stack(self, profile, clock, wrong_dsp=False, bridge_line=True):
        self.write("stage", f"{int(clock)} running\n")
        self.write("recovers", "")
        lines = ["NEGOTIATED usb_capture=48/192", "ALIGN status=ok", "PRIMED direction=usb-to-ravenna front_age_frames=296"]
        if profile == "dsp-loaded" and not wrong_dsp:
            lines = ["DSP loaded file=/etc/usb16x16/dsp/loaded.dsp biquads=308"] + lines + ["DSP engaged direction=usb-to-ravenna biquads=308"]
        if profile == "dsp-direct" and wrong_dsp:
            lines = ["DSP loaded file=/etc/usb16x16/dsp/loaded.dsp biquads=308"] + lines
        self.write("bridge.log", "\n".join(lines) + "\n" + "BRIDGE ppm=-14 tx_restarts=0 rx_restarts=0\n" * 3)
        (self.run_dir / "last-bridge").unlink(missing_ok=True)
        if bridge_line:
            self.touch_bridge(clock)

    def touch_bridge(self, clock):
        self.write("last-bridge", "BRIDGE ppm=-14.0 tx_queue=176 rx_queue=140 tx_restarts=0 rx_restarts=0 tx_qfloor=84\n")
        os.utime(self.run_dir / "last-bridge", (clock, clock))

    def request(self, **fields):
        body = {"id": "abcdef0123", "profile": "dsp-loaded", "expectedProfile": "dsp-direct",
                "requestedAt": time.time(), "requestedBy": "bryan"}
        body.update(fields)
        (self.spool / "request.json").write_text(json.dumps(body))
        return body


def make(env, runner):
    return apply_module.Applier(spool=env.spool, conf_path=env.conf, run_dir=env.run_dir, runner=runner,
                                supervisor="/fake/supervisor", bridge_binary=env.root / "missing",
                                start_timeout=20.0, settle=5.0, poll=1.0)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = Env(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def receipt(self, ident="abcdef0123"):
        return json.loads((self.env.spool / "receipts" / f"{ident}.json").read_text())

    def test_conf_parser_and_profiles(self):
        table = apply_module.profiles(apply_module.parse_conf(CONF))
        self.assertEqual(sorted(table), ["dsp-direct", "dsp-loaded", "fast"])
        self.assertTrue(table["dsp-loaded"]["accepted"])
        self.assertEqual(table["dsp-loaded"]["dspPreset"], "/etc/usb16x16/dsp/loaded.dsp")
        self.assertEqual(table["dsp-direct"]["description"], "no preset")
        self.assertFalse(table["fast"]["accepted"])

    def test_happy_path_switches_and_verifies(self):
        runner = FakeRunner(self.env)
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertEqual([s["name"] for s in result["steps"]],
                         ["validating", "stopping", "switching", "starting", "verifying", "settling"])
        self.assertEqual(self.env.live_profile(), "dsp-loaded")
        self.assertEqual(result["live"], "dsp-loaded")
        self.assertEqual(result["previousProfile"], "dsp-direct")
        self.assertFalse((self.env.spool / "request.json").exists(), "the request is consumed")
        self.assertEqual(self.receipt()["state"], "done")
        self.assertTrue(any(v.startswith("DSP loaded") for v in result["startLines"]["dsp-loaded"]))
        self.assertEqual(json.loads((self.env.spool / "current.json").read_text())["state"], "done")

    def test_refusals_leave_the_service_alone(self):
        cases = [
            (dict(profile="fast"), "not accepted"),
            (dict(profile="nope"), "no block"),
            (dict(profile="Bad Name"), "lower-case"),
            (dict(expectedProfile="dsp-loaded"), "expected dsp-loaded"),
            (dict(profile="dsp-direct"), "already the live"),
            (dict(requestedAt=time.time() - 1000), "old"),
            (dict(id="zz"), "hex"),
        ]
        for index, (fields, message) in enumerate(cases):
            with self.subTest(fields=fields):
                runner = FakeRunner(self.env)
                self.env.request(**{"id": f"{index:08x}", **fields})
                result = make(self.env, runner).consume()
                self.assertEqual(result["state"], "refused")
                self.assertIn(message, result["error"])
                self.assertEqual([c for c in runner.calls if c[0] != "systemctl" or c[1] != "show"], [])
                self.assertEqual(self.env.live_profile(), "dsp-direct")

    def test_duplicate_id_is_refused(self):
        self.env.request()
        make(self.env, FakeRunner(self.env)).consume()
        self.env.set_profile("dsp-direct")
        self.env.request()
        result = make(self.env, FakeRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("already processed", result["error"])

    def test_garbage_request_is_refused_and_consumed(self):
        (self.env.spool / "request.json").write_text("{not json")
        result = make(self.env, FakeRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertFalse((self.env.spool / "request.json").exists())
        self.assertIsNone(make(self.env, FakeRunner(self.env)).consume(), "nothing pending afterwards")

    def test_start_failure_rolls_back(self):
        runner = FakeRunner(self.env, fail_start_for="dsp-loaded")
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "rolled-back", result)
        self.assertIn("failed: daemon API", result["error"])
        self.assertEqual(self.env.live_profile(), "dsp-direct")
        names = [s["name"] for s in result["steps"]]
        self.assertIn("rolling-back", names)
        self.assertEqual(names.count("starting"), 2)
        self.assertEqual(runner.unit, "active")

    def test_recover_in_settle_rolls_back(self):
        runner = FakeRunner(self.env, recover_during_settle_for="dsp-loaded")
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "rolled-back", result)
        self.assertIn("RECOVER", result["error"])
        self.assertEqual(self.env.live_profile(), "dsp-direct")

    def test_missing_dsp_lines_roll_back(self):
        runner = FakeRunner(self.env, wrong_dsp_for="dsp-loaded")
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "rolled-back", result)
        self.assertIn("DSP loaded", result["error"])

    def test_preset_on_direct_profile_is_a_failure(self):
        self.env.set_profile("dsp-loaded")
        runner = FakeRunner(self.env, wrong_dsp_for="dsp-direct")
        self.env.request(profile="dsp-direct", expectedProfile="dsp-loaded")
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "rolled-back")
        self.assertIn("without one", result["error"])

    def test_switch_refusal_rolls_back_without_a_second_switch_failure(self):
        runner = FakeRunner(self.env, fail_switch="dsp-loaded")
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "rolled-back", result)
        self.assertIn("switch-profile refused", result["error"])
        self.assertEqual(self.env.live_profile(), "dsp-direct")
        self.assertEqual(runner.unit, "active")

    def test_double_failure_is_failed_with_both_reasons(self):
        runner = FakeRunner(self.env, fail_start_for="dsp-loaded")
        # make the rollback fail too: the direct profile now starts with a preset
        runner.wrong_dsp_for = "dsp-direct"
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "failed", result)
        self.assertIn("rollback to dsp-direct also failed", result["error"])

    def test_first_bridge_line_may_lag_stage_running(self):
        runner = FakeRunner(self.env, bridge_line_delay=3)
        self.env.request()
        result = make(self.env, runner).consume()
        self.assertEqual(result["state"], "done", result)

    def test_no_bridge_line_at_all_rolls_back(self):
        runner = FakeRunner(self.env, never_bridge_line=True)
        self.env.request()
        applier = make(self.env, runner)
        result = applier.consume()
        self.assertEqual(result["state"], "failed", result)
        self.assertIn("no BRIDGE telemetry line", result["error"])

    def test_check_mode_reports_without_acting(self):
        self.env.request()
        applier = make(self.env, FakeRunner(self.env))
        target = applier.validate(applier.load_request(), applier.conf())
        self.assertEqual(target["name"], "dsp-loaded")
        self.assertTrue((self.env.spool / "request.json").exists())


if __name__ == "__main__":
    unittest.main()
