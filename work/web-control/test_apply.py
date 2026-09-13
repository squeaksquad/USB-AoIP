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
        # the bridge loads whatever preset the live profile's block names
        conf = apply_module.parse_conf(self.conf.read_text())
        preset = conf.get(f"PROFILE_{apply_module.profile_key(profile)}_DSP_PRESET", "")
        if preset and not wrong_dsp:
            lines = [f"DSP loaded file={preset} biquads=308"] + lines + ["DSP engaged direction=usb-to-ravenna biquads=308"]
        if not preset and wrong_dsp:
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


# ------------------------------------------------------------- presets

REPO = HERE.parent.parent
REAL_ARTIFACT = REPO / "outputs/dsp-service/review-20260911/candidate/transparent.dsp"

PRESET_CONF = """PROFILE=dsp-direct
PROFILE_DSP_DIRECT_DESCRIPTION="sd103 transport on the DSP bridge, no preset"
PROFILE_DSP_DIRECT_STATUS=accepted
PROFILE_DSP_DIRECT_COVER="x"
PROFILE_DSP_DIRECT_MEASURED="y"
PROFILE_DSP_DIRECT_PERIOD=48
PROFILE_DSP_DIRECT_BUFFER=192
PROFILE_DSP_DIRECT_TARGET=48
PROFILE_DSP_DIRECT_SINK_DELAY=103
PROFILE_DSP_LOADED_STATUS=accepted
PROFILE_DSP_LOADED_TARGET=48
PROFILE_DSP_LOADED_DSP_PRESET=/etc/usb16x16/dsp/loaded.dsp
PROFILE_DSP_LOADED_DSP_SHA256=2b6baa04
"""


class PresetRunner(FakeRunner):
    """FakeRunner plus the offline runner and the supervisor's `profiles` on a
    temporary conf, which it answers by parsing the file the way the
    supervisor would list it."""

    def __init__(self, env, loader_refuses=False, **kw):
        super().__init__(env, **kw)
        self.loader_refuses = loader_refuses
        self.profiles_calls = []

    def run(self, argv, timeout=60.0, env=None):
        if argv[0] == apply_module.OFFLINE_RUNNER:
            self.calls.append(argv)
            if self.loader_refuses:
                return 4, "dsp artifact: a pipeline with no internal channels routes nothing"
            return 0, "loaded preset x: 16 internal, 256 sections BENCH"
        if argv[1] == "profiles":
            self.profiles_calls.append(env)
            text = Path(env["USB16X16_AES67_CONF"]).read_text()
            conf = apply_module.parse_conf(text)
            for line in text.splitlines():
                if line and not line.startswith("#") and "=" not in line:
                    return 1, f"bad line in conf: {line}"
            out = "\n".join(f"  {name}: {row['status']}, cover: {row['cover']}" for name, row in sorted(apply_module.profiles(conf).items()))
            return 0, out
        return super().run(argv, timeout)


class PresetFixture(unittest.TestCase):
    """The preset environment: a conf with dsp-direct live, a DSP directory
    and a stub offline runner. Test classes inherit it; it holds no tests."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = Env(self.tmp.name)
        self.env.conf.write_text(PRESET_CONF)
        (self.env.spool / "presets").mkdir()
        self.dsp_dir = Path(self.tmp.name) / "dsp"
        self.dsp_dir.mkdir()
        runner_path = Path(self.tmp.name) / "usb16x16-dsp-offline"
        runner_path.write_text("#!/bin/sh\n")
        self.saved = (apply_module.DSP_DIR, apply_module.OFFLINE_RUNNER)
        apply_module.DSP_DIR = self.dsp_dir
        apply_module.OFFLINE_RUNNER = str(runner_path)
        self.artifact = REAL_ARTIFACT.read_bytes()

    def tearDown(self):
        apply_module.DSP_DIR, apply_module.OFFLINE_RUNNER = self.saved
        self.tmp.cleanup()

    def preset_request(self, data=None, **fields):
        data = self.artifact if data is None else data
        ident = fields.pop("id", "abcdef0123")
        (self.env.spool / "presets" / f"{ident}.dsp").write_bytes(data)
        body = {"id": ident, "kind": "preset", "name": "Room A · night", "slug": "room-a-night",
                "artifactSha256": __import__("hashlib").sha256(data).hexdigest(), "artifactFile": f"{ident}.dsp",
                "expectedProfile": "dsp-direct", "requestedAt": time.time(), "requestedBy": "bryan"}
        body.update(fields)
        (self.env.spool / "request.json").write_text(json.dumps(body))
        return body

    def make(self, runner):
        applier = make(self.env, runner)
        return applier


class PresetTests(PresetFixture):
    def test_real_artifact_parses_with_the_loader_bounds(self):
        stats = apply_module.parse_artifact(self.artifact.decode())
        self.assertEqual(stats["biquads"], 256)
        self.assertEqual(stats["internal"], 16)
        self.assertEqual(stats["maxDelay"], 0)
        self.assertEqual(stats["preset"], "verify-transparent")

    def test_parser_refuses_what_the_loader_would_and_unstable_sections(self):
        text = self.artifact.decode()
        with self.assertRaisesRegex(apply_module.Refused, "channel count"):
            apply_module.parse_artifact(text.replace("channels 16", "channels 8", 1))
        with self.assertRaisesRegex(apply_module.Refused, "ends early|expected 'end'"):
            apply_module.parse_artifact(text.replace("\nend\n", "\n"))
        lines = text.split("\n")
        branch_at = next(i for i, l in enumerate(lines) if l.startswith("branch "))
        first_section = next(i for i, l in enumerate(lines) if i > branch_at and len(l.split()) == 5)
        parts = lines[first_section].split()
        parts[4] = "1.5"  # a2 outside the unit circle
        lines[first_section] = " ".join(parts)
        with self.assertRaisesRegex(apply_module.Refused, "unstable"):
            apply_module.parse_artifact("\n".join(lines))

    def test_biquad_cap(self):
        text = self.artifact.decode().replace("branch 16\n", "branch 16\n", 1)
        # 256 real sections plus 64 on a synthetic output row pushes past 308
        text = text.replace("output 16\n", "output 16\n", 1)
        section = "1 0 0 0 0\n"
        text = text.replace("\nend\n", "\n15 0 1 64\n" + section * 64 + "end\n")
        text = text.replace("output 16\n", "output 17\n", 1)
        with self.assertRaisesRegex(apply_module.Refused, "over the bridge's limit|over the 308"):
            apply_module.parse_artifact(text)

    def test_preset_install_and_switch(self):
        runner = PresetRunner(self.env)
        self.preset_request()
        result = self.make(runner).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertEqual(result["kind"], "preset")
        self.assertEqual(result["profile"], "user-room-a-night")
        self.assertEqual(self.env.live_profile(), "user-room-a-night")
        names = [s["name"] for s in result["steps"]]
        self.assertEqual(names[:5], ["validating", "checking", "installing", "validating", "stopping"])
        self.assertTrue((self.dsp_dir / "user-room-a-night.dsp").read_bytes() == self.artifact)
        conf = self.env.conf.read_text()
        self.assertIn("PROFILE_USER_ROOM_A_NIGHT_TARGET=48", conf)
        self.assertIn("PROFILE_USER_ROOM_A_NIGHT_SINK_DELAY=103", conf)
        self.assertIn("PROFILE_USER_ROOM_A_NIGHT_STATUS=experimental", conf)
        self.assertIn(f"PROFILE_USER_ROOM_A_NIGHT_DSP_PRESET={self.dsp_dir}/user-room-a-night.dsp", conf)
        self.assertNotIn("PROFILE_USER_ROOM_A_NIGHT_DSP_SHA256=2b6baa04", conf)
        self.assertIn("256 biquads", conf)
        self.assertEqual(len(runner.profiles_calls), 1, "the supervisor validated the new conf once")
        self.assertFalse((self.env.spool / "presets" / "abcdef0123.dsp").exists(), "the uploaded artifact is consumed")
        self.assertEqual(result["stats"]["biquads"], 256)
        self.assertIn("BENCH", result["loaderLine"])

    def test_bad_hash_and_missing_file_are_refused(self):
        self.preset_request(artifactSha256="0" * 64)
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("hash does not match", result["error"])
        self.preset_request(id="1234567890ab")
        (self.env.spool / "presets" / "1234567890ab.dsp").unlink()
        result = self.make(PresetRunner(self.env)).consume()
        self.assertIn("missing from the spool", result["error"])
        self.assertEqual(self.env.live_profile(), "dsp-direct")
        self.assertEqual(list(self.dsp_dir.iterdir()), [])

    def test_loader_refusal_leaves_nothing_installed(self):
        self.preset_request()
        result = self.make(PresetRunner(self.env, loader_refuses=True)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("loader refused", result["error"])
        self.assertEqual(list(self.dsp_dir.iterdir()), [])
        self.assertNotIn("PROFILE_USER_", self.env.conf.read_text())

    def test_replacing_a_slug_rewrites_one_block(self):
        self.preset_request()
        self.make(PresetRunner(self.env)).consume()
        changed = self.artifact.replace(b"preset verify-transparent", b"preset verify-transparent v2")
        self.preset_request(data=changed, id="feedfacefeed", expectedProfile="user-room-a-night")
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused", "the target is already live")
        self.assertIn("already the live", result["error"])
        # switch away, then replace
        self.env.set_profile("dsp-direct")
        self.preset_request(data=changed, id="feedfacefee1", expectedProfile="dsp-direct")
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "done", result)
        conf = self.env.conf.read_text()
        self.assertEqual(conf.count("PROFILE_USER_ROOM_A_NIGHT_TARGET="), 1)
        self.assertEqual(conf.count("# user preset [user-room-a-night]"), 1)
        self.assertEqual((self.dsp_dir / "user-room-a-night.dsp").read_bytes(), changed)

    def test_slug_conflict_and_cap(self):
        self.preset_request()
        self.make(PresetRunner(self.env)).consume()
        self.env.set_profile("dsp-direct")
        self.preset_request(id="00000000ab", slug="room-a", expectedProfile="dsp-direct")
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("collide", result["error"])
        for n in range(7):
            self.preset_request(id=f"{n:010x}", slug=f"p{n}", expectedProfile="dsp-direct")
            self.assertEqual(self.make(PresetRunner(self.env)).consume()["state"], "done")
            self.env.set_profile("dsp-direct")
        self.preset_request(id="aaaaaaaaaa", slug="ninth", expectedProfile="dsp-direct")
        result = self.make(PresetRunner(self.env)).consume()
        self.assertIn("remove one first", result["error"])

    def test_remove(self):
        self.preset_request()
        self.make(PresetRunner(self.env)).consume()
        (self.env.spool / "request.json").write_text(json.dumps({"id": "bbbbbbbbbb", "kind": "remove", "slug": "room-a-night",
                                                                  "requestedAt": time.time()}))
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("live profile", result["error"])
        self.env.set_profile("dsp-direct")
        (self.env.spool / "request.json").write_text(json.dumps({"id": "cccccccccc", "kind": "remove", "slug": "room-a-night",
                                                                  "requestedAt": time.time()}))
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertNotIn("PROFILE_USER_", self.env.conf.read_text())
        self.assertEqual(list(self.dsp_dir.iterdir()), [])

    def test_profile_switch_to_a_user_block_needs_the_pinned_file(self):
        self.preset_request()
        self.make(PresetRunner(self.env)).consume()
        self.env.set_profile("dsp-direct")
        (self.dsp_dir / "user-room-a-night.dsp").write_bytes(b"tampered")
        self.env.request(id="dddddddddd", profile="user-room-a-night", expectedProfile="dsp-direct")
        result = self.make(PresetRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("not accepted", result["error"])


# ---------------------------------------------------------------- live updates
# LIVE_COEFFICIENTS_DESIGN.md step 4: the "live" and "commit" kinds.

PINNED_VECTOR = (
    "usb16x16-dsp 1\npreset pinned shape vector\nrate 48000\nchannels 16\ninternal 2\nmaxdelay 480\n"
    "expand 2\n0 0 0.125\n1 1 -0.5\nbranch 1\n1 2\n1 0 0 0 0\n0.5 0.25 0 -0.1 0.01\n"
    "assign 2\n0 0 1\n3 1 0\noutput 16\n0 48 0.5 1\n1 0 0 0 0\n"
    + "".join(f"{i} 0 1 0\n" for i in range(1, 16)) + "end\n")
PINNED_KEY = "7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0"


class ShapeTests(unittest.TestCase):
    def test_pinned_vector(self):
        self.assertEqual(apply_module.shape_key(PINNED_VECTOR), PINNED_KEY,
                         "the applier must agree with bridge-artifact.test.mjs and bridge_tests.cpp")
        shape = apply_module.artifact_shape(PINNED_VECTOR)
        self.assertTrue(shape.startswith("usb16x16-dsp-shape 1\nrate 48000\nchannels 16\ninternal 2\nmaxdelay 480\nexpand 2\n0 0\n1 1\nbranch 1\n1 2\nassign 2\n0 0\n3 1\noutput 16\n0 1\n1 0\n"))
        self.assertTrue(shape.endswith("15 0\nend\n"))

    def test_values_are_not_shape_and_counts_are(self):
        renumbered = PINNED_VECTOR.replace("0 48 0.5 1", "0 96 0.25 1").replace("0.5 0.25 0 -0.1 0.01", "0.6 0.2 0 -0.2 0.02")
        self.assertEqual(apply_module.shape_key(renumbered), PINNED_KEY)
        reshaped = PINNED_VECTOR.replace("assign 2\n0 0 1\n3 1 0", "assign 1\n0 0 1")
        self.assertNotEqual(apply_module.shape_key(reshaped), PINNED_KEY)
        with self.assertRaises(apply_module.Refused):
            apply_module.artifact_shape(PINNED_VECTOR.replace("end\n", ""))

    def test_real_artifact_has_a_shape(self):
        text = REAL_ARTIFACT.read_text()
        self.assertEqual(len(apply_module.shape_key(text)), 64)

    def test_live_status_line(self):
        line = 'DSPLIVE gen=43 sha256=abc state=applied reason="" t_us=100\n'
        self.assertEqual(apply_module.parse_live_status(line), {"gen": "43", "sha256": "abc", "state": "applied", "reason": "", "t_us": "100"})
        line = 'DSPLIVE gen=0 sha256=def state=refused reason="shape differs" t_us=5\n'
        self.assertEqual(apply_module.parse_live_status(line)["reason"], "shape differs")
        self.assertIsNone(apply_module.parse_live_status("BRIDGE ppm=1\n"))
        self.assertIsNone(apply_module.parse_live_status(None))


class LiveRunner(PresetRunner):
    """PresetRunner plus a model of the bridge's control thread: every sleep,
    if the live file holds something new, the status line answers it."""

    def __init__(self, env, bridge_refuses=None, bridge_silent=False, **kw):
        super().__init__(env, **kw)
        self.bridge_refuses = bridge_refuses
        self.bridge_silent = bridge_silent
        self.seen = None
        self.gen = 0

    def sleep(self, seconds):
        super().sleep(seconds)
        live = self.env.run_dir / "dsp-live.dsp"
        if self.bridge_silent or not live.exists():
            return
        data = live.read_bytes()
        if data == self.seen:
            return
        self.seen = data
        digest = __import__("hashlib").sha256(data).hexdigest()
        if self.bridge_refuses:
            line = f'DSPLIVE gen={self.gen} sha256={digest} state=refused reason="{self.bridge_refuses}" t_us=1\n'
        else:
            self.gen += 1
            line = f'DSPLIVE gen={self.gen} sha256={digest} state=applied reason="" t_us=1\n'
        self.env.write("dsp-live.status", line)


class LiveTests(PresetFixture):
    """Starts from an installed, live user preset (through the preset kind),
    then exercises live and commit against it."""

    def setUp(self):
        super().setUp()
        self.preset_request()
        result = self.make(PresetRunner(self.env)).consume()
        assert result["state"] == "done", result
        self.installed = self.dsp_dir / "user-room-a-night.dsp"
        # A same-shape variant: the first output gain halved.
        text = self.artifact.decode()
        lines = text.split("\n")
        at = next(i for i, l in enumerate(lines) if l.startswith("output "))
        parts = lines[at + 1].split(" ")
        parts[2] = str(float(parts[2]) * 0.5)
        lines[at + 1] = " ".join(parts)
        self.variant = "\n".join(lines).encode()
        assert apply_module.shape_key(self.variant.decode()) == apply_module.shape_key(text)
        self.env.write("dsp-live.status", 'DSPLIVE gen=0 sha256=none state=idle reason="no live file yet" t_us=1\n')

    def live_request(self, data=None, **fields):
        data = self.variant if data is None else data
        ident = fields.pop("id", "1234567890ab")
        (self.env.spool / "presets" / f"{ident}.dsp").write_bytes(data)
        body = {"id": ident, "kind": "live", "artifactSha256": __import__("hashlib").sha256(data).hexdigest(),
                "artifactFile": f"{ident}.dsp", "expectedProfile": "user-room-a-night",
                "requestedAt": time.time(), "requestedBy": "bryan"}
        body.update(fields)
        (self.env.spool / "request.json").write_text(json.dumps(body))
        return body

    def commit_request(self, **fields):
        body = {"id": "fedcba987654", "kind": "commit", "expectedProfile": "user-room-a-night",
                "requestedAt": time.time(), "requestedBy": "bryan"}
        body.update(fields)
        (self.env.spool / "request.json").write_text(json.dumps(body))
        return body

    def test_user_block_carries_dsp_live(self):
        self.assertIn("PROFILE_USER_ROOM_A_NIGHT_DSP_LIVE=1", self.env.conf.read_text())

    def test_live_push_is_applied_without_a_restart(self):
        runner = LiveRunner(self.env)
        self.live_request()
        result = self.make(runner).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertEqual(result["kind"], "live")
        self.assertEqual([s["name"] for s in result["steps"]], ["validating", "checking", "pushing", "verifying"])
        self.assertEqual(result["liveUpdate"]["gen"], "1")
        self.assertEqual(result["liveUpdate"]["sha256"], __import__("hashlib").sha256(self.variant).hexdigest())
        self.assertEqual((self.env.run_dir / "dsp-live.dsp").read_bytes(), self.variant)
        self.assertEqual(self.installed.read_bytes(), self.artifact, "nothing installed by a live push")
        self.assertFalse(any(c[:2] == ["systemctl", "stop"] for c in runner.calls), "no restart")
        self.assertTrue(any(c[0] == apply_module.OFFLINE_RUNNER for c in runner.calls), "load-checked first")
        self.assertFalse((self.env.spool / "presets" / "1234567890ab.dsp").exists(), "the upload is consumed")

    def test_live_refuses_a_different_shape(self):
        reshaped = self.artifact.decode().replace("assign 16\n", "assign 15\n", 1)
        # drop one assign row so the count stays honest
        lines = reshaped.split("\n")
        at = next(i for i, l in enumerate(lines) if l.startswith("assign "))
        del lines[at + 1]
        self.live_request("\n".join(lines).encode())
        result = self.make(LiveRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("shape differs", result["error"])
        self.assertFalse((self.env.run_dir / "dsp-live.dsp").exists())

    def test_live_refuses_on_an_accepted_profile_and_without_dsp_live(self):
        self.env.set_profile("dsp-direct")
        self.live_request(expectedProfile="dsp-direct")
        result = self.make(LiveRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("not a user preset", result["error"])
        self.env.set_profile("user-room-a-night")
        conf = self.env.conf.read_text().replace("PROFILE_USER_ROOM_A_NIGHT_DSP_LIVE=1\n", "")
        self.env.conf.write_text(conf)
        self.live_request()
        result = self.make(LiveRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("DSP_LIVE", result["error"])

    def test_live_refuses_a_stale_page(self):
        self.live_request(expectedProfile="dsp-direct")
        result = self.make(LiveRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("expected dsp-direct", result["error"])
        self.live_request(expectedLiveSha256="0" * 64)
        result = self.make(LiveRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("bridge reports none", result["error"])

    def test_bridge_refusal_and_silence_are_failed_not_refused(self):
        self.live_request()
        result = self.make(LiveRunner(self.env, bridge_refuses="shape differs")).consume()
        self.assertEqual(result["state"], "failed")
        self.assertIn("refused the artifact: shape differs", result["error"])
        self.live_request()
        result = self.make(LiveRunner(self.env, bridge_silent=True)).consume()
        self.assertEqual(result["state"], "failed")
        self.assertIn("did not report", result["error"])
        self.assertTrue((self.env.run_dir / "dsp-live.dsp").exists(), "left for the bridge")

    def test_commit_makes_the_live_file_the_installed_preset(self):
        runner = LiveRunner(self.env)
        self.live_request()
        assert self.make(runner).consume()["state"] == "done"
        digest = __import__("hashlib").sha256(self.variant).hexdigest()
        self.commit_request(expectedLiveSha256=digest)
        result = self.make(runner).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertEqual(result["kind"], "commit")
        self.assertTrue(result["committed"]["changed"])
        self.assertEqual(self.installed.read_bytes(), self.variant)
        conf = self.env.conf.read_text()
        self.assertIn(f"PROFILE_USER_ROOM_A_NIGHT_DSP_SHA256={digest}", conf)
        self.assertEqual(conf.count("PROFILE_USER_ROOM_A_NIGHT_DSP_SHA256="), 1)
        self.assertIn("PROFILE_USER_ROOM_A_NIGHT_DSP_LIVE=1", conf)
        self.assertFalse(any(c[:2] == ["systemctl", "stop"] for c in runner.calls), "commit never restarts")
        self.assertEqual(len(runner.profiles_calls), 1, "the supervisor validated the rewritten conf")
        # A second commit of the same coefficients changes nothing.
        self.commit_request(id="fedcba987655")
        result = self.make(runner).consume()
        self.assertEqual(result["state"], "done")
        self.assertFalse(result["committed"]["changed"])

    def test_commit_with_nothing_applied_is_refused(self):
        self.commit_request()
        result = self.make(LiveRunner(self.env)).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("nothing applied", result["error"])

    def test_commit_refuses_a_live_file_that_moved(self):
        runner = LiveRunner(self.env)
        self.live_request()
        assert self.make(runner).consume()["state"] == "done"
        (self.env.run_dir / "dsp-live.dsp").write_bytes(self.artifact)   # changed behind the bridge's back
        self.commit_request()
        result = self.make(runner).consume()
        self.assertEqual(result["state"], "refused")
        self.assertIn("no longer matches", result["error"])

    def test_revert_pushes_the_installed_file_back(self):
        runner = LiveRunner(self.env)
        self.live_request()
        assert self.make(runner).consume()["state"] == "done"
        body = {"id": "abcdefabcdef", "kind": "live", "revert": True, "expectedProfile": "user-room-a-night",
                "requestedAt": time.time(), "requestedBy": "bryan"}
        (self.env.spool / "request.json").write_text(json.dumps(body))
        result = self.make(runner).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertEqual(result["liveUpdate"]["sha256"], __import__("hashlib").sha256(self.artifact).hexdigest())
        self.assertEqual((self.env.run_dir / "dsp-live.dsp").read_bytes(), self.artifact)
        self.assertFalse(any(c[:2] == ["systemctl", "stop"] for c in runner.calls))
