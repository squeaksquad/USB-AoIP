"""Tests for usb16x16-apply's Dante backend: the same requests against
usb16x16-dante.service, with systemd and the owner stood in by a scripted
runner and the configuration checked by the real usb16x16-dante-start.
Run: python3 -m unittest work/web-control/test_dante_apply.py"""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
loader = importlib.machinery.SourceFileLoader("usb16x16_apply_dante", str(HERE / "usb16x16-apply"))
spec = importlib.util.spec_from_loader("usb16x16_apply_dante", loader)
apply_module = importlib.util.module_from_spec(spec)
loader.exec_module(apply_module)

START = REPO / "work/dante-mode/service/usb16x16-dante-start"


def artifact(gain=1.0, inputs=16, name="straight", rate=48000):
    rows = lambda count, fmt: "".join(fmt(c) for c in range(count))
    return ("usb16x16-dsp 1\npreset " + name + f"\nrate {rate}\nchannels 16\ninternal 16\nmaxdelay {rate // 100}\n"
            f"expand {inputs}\n" + rows(inputs, lambda c: f"{c} {c} {gain}\n") + "branch 0\nassign 16\n"
            + rows(16, lambda c: f"{c} {c} 1\n") + "output 16\n" + rows(16, lambda c: f"{c} 0 1 0\n") + "end\n").encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


class FakeRunner:
    """systemd, the journal and the owner as a small model; the wrapper is the real one."""

    def __init__(self, env, fail_start_for=None, fatal_after_start_for=None, never_netstart_for=None,
                 restart_during_settle_for=None, owner_ignores_live=False, owner_refuses_live=False):
        self.env = env
        self.clock = time.time()
        self.unit = "active"
        self.invocation = 1
        self.log = env.start_lines(env.live())
        self.calls = []
        self.fail_start_for = fail_start_for
        self.fatal_after_start_for = fatal_after_start_for
        self.never_netstart_for = never_netstart_for
        self.restart_during_settle_for = restart_during_settle_for
        self.owner_ignores_live = owner_ignores_live
        self.owner_refuses_live = owner_refuses_live
        self.ticks = 0
        self.seen_live = None
        self.generation = 0

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds
        self.ticks += 1
        live = self.env.live()
        if self.unit == "active" and self.fatal_after_start_for == live and self.ticks == 3:
            self.log.append("NETERROR count=1 last=-32 (Broken pipe) t=3.000")
        if self.unit == "active" and self.restart_during_settle_for == live and self.ticks == 4:
            self.invocation += 1
        # the owner's live follower
        path = self.env.run_dir / "dsp-live.dsp"
        if self.unit == "active" and path.exists() and not self.owner_ignores_live:
            data = path.read_bytes()
            if sha(data) != self.seen_live:
                self.seen_live = sha(data)
                state = "refused" if self.owner_refuses_live else "applied"
                reason = "shape differs" if self.owner_refuses_live else ""
                if state == "applied":
                    self.generation += 1
                (self.env.run_dir / "dsp-live.status").write_text(
                    f'DSPLIVE gen={self.generation} sha256={self.seen_live} state={state} reason="{reason}" t_us={int(self.clock * 1e6)}\n')

    def run(self, argv, timeout=60.0, env=None):
        self.calls.append(argv)
        if argv[:3] == ["systemctl", "show", "-p"]:
            return 0, self.unit if argv[3] == "ActiveState" else f"inv{self.invocation}"
        if argv[:2] == ["systemctl", "reset-failed"]:
            return 0, ""
        if argv[:2] == ["systemctl", "stop"]:
            self.unit = "inactive"
            for name in ("dsp-live.dsp", "dsp-live.status"):   # RuntimeDirectory goes with the unit
                (self.env.run_dir / name).unlink(missing_ok=True)
            return 0, ""
        if argv[:2] == ["systemctl", "start"]:
            live = self.env.live()
            self.invocation += 1
            self.ticks = 0
            self.seen_live = None
            self.generation = 0
            if self.fail_start_for == live:
                self.unit = "failed"
                self.log = ["usb16x16-dante-start: REFUSED: DSP_PRESET is missing or unreadable"]
                return 0, ""
            self.unit = "active"
            self.log = self.env.start_lines(live, netstart=self.never_netstart_for != live)
            return 0, ""
        if argv[0] == "journalctl":
            return 0, "\n".join(self.log) if argv[-1] == f"_SYSTEMD_INVOCATION_ID=inv{self.invocation}" else ""
        if argv[0] == apply_module.DANTE_START:
            completed = subprocess.run([str(START), "--print"], capture_output=True, text=True,
                                       env={**os.environ, **(env or {}), "USB16X16_DSP_DIR": str(self.env.dsp_dir)})
            return completed.returncode, completed.stdout + completed.stderr
        if argv[0] == apply_module.OFFLINE_RUNNER:
            return 0, "loaded preset internal=16 biquads=0"
        if argv[:2] == ["systemctl", "poweroff"]:
            return 0, ""
        raise AssertionError(f"unexpected command {argv}")


class Env:
    def __init__(self, root):
        self.root = Path(root)
        self.spool = self.root / "spool"
        (self.spool / "presets").mkdir(parents=True)
        self.run_dir = self.root / "run"
        self.run_dir.mkdir()
        self.dsp_dir = self.root / "dsp"
        self.dsp_dir.mkdir()
        self.conf = self.root / "owner.conf"
        self.conf.write_text("# as installed\nMETERS=1\n")

    def conf_values(self):
        return apply_module.parse_owner_conf(self.conf.read_text())

    def live(self):
        return apply_module.dante_profile_of(self.conf_values())

    def install(self, slug, data):
        path = self.dsp_dir / f"dante-{slug}.dsp"
        path.write_bytes(data)
        return path

    def start_lines(self, live, netstart=True):
        lines = ["START usb16x16-dante-owner mode=usb pcm=inferno"]
        if live != "direct":
            preset = self.conf_values()["DSP_PRESET"]
            lines += [f"DSP loaded file={preset} preset=\"x\" internal=16 biquads=0 delay_frames=0 shape=abc",
                      "DSPLIVE following file=/run/usb16x16-dante/dsp-live.dsp status=/run/usb16x16-dante/dsp-live.dsp.status"]
        if self.conf_values().get("METERS") == "1":
            lines.append("METERS publishing file=/run/usb16x16-dante/meters.txt window_frames=2400")
        if netstart:
            lines.append("NETSTART capture=RUNNING playback=RUNNING")
        return lines


class DanteApplyTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.env = Env(self.directory.name)
        runner_path = Path(self.directory.name) / "offline"
        runner_path.write_text("")
        self.saved = (apply_module.DSP_DIR, apply_module.OFFLINE_RUNNER)
        apply_module.DSP_DIR = self.env.dsp_dir
        apply_module.OFFLINE_RUNNER = str(runner_path)
        self.counter = 0

    def tearDown(self):
        apply_module.DSP_DIR, apply_module.OFFLINE_RUNNER = self.saved
        self.directory.cleanup()

    def make(self, runner=None, **options):
        self.runner = runner or FakeRunner(self.env, **options)
        return apply_module.DanteApplier(spool=self.env.spool, conf_path=self.env.conf, run_dir=self.env.run_dir,
                                         runner=self.runner, start_timeout=20, settle=5, poll=1)

    def request(self, **fields):
        self.counter += 1
        base = {"id": f"{self.counter:08x}", "requestedAt": time.time(), "requestedBy": "test"}
        base.update(fields)
        return base

    def with_artifact(self, data, **fields):
        request = self.request(**fields)
        (self.env.spool / "presets" / f"{request['id']}.dsp").write_bytes(data)
        request.update(artifactFile=f"{request['id']}.dsp", artifactSha256=sha(data))
        return request

    def with_rates(self, request, rates):
        """Add rateArtifacts {rate: data} to a request, files in the spool as the web service writes them."""
        extra = {}
        for rate, data in rates.items():
            name = f"{request['id']}-{rate}.dsp"
            (self.env.spool / "presets" / name).write_bytes(data)
            extra[str(rate)] = {"file": name, "sha256": sha(data)}
        request["rateArtifacts"] = extra
        return request

    def load_checks(self):
        return [c[1:] for c in self.runner.calls if c[0] == apply_module.OFFLINE_RUNNER]

    def commands(self):
        return [" ".join(c[:2]) for c in self.runner.calls if c[0] == "systemctl" and c[1] in ("stop", "start", "poweroff")]

    # ---- parsing and rendering

    def test_owner_conf_round_trip_is_what_the_wrapper_accepts(self):
        path = self.env.install("a", artifact())
        text = apply_module.render_owner_conf("1", path, sha(artifact()))
        values = apply_module.parse_owner_conf(text)
        self.assertEqual(values, {"METERS": "1", "DSP_PRESET": str(path), "DSP_SHA256": sha(artifact()), "DSP_LIVE": "1"})
        self.assertEqual(apply_module.dante_profile_of(values), "dante-a")
        self.assertEqual(apply_module.dante_profile_of({"METERS": "1"}), "direct")
        self.assertNotIn("DSP_", apply_module.render_owner_conf("0", None, None))
        with self.assertRaises(apply_module.Refused):
            apply_module.parse_owner_conf("METERS=1\nPROFILE=dsp-direct\n")

    def test_stack_detection(self):
        class Enabled:
            def __init__(self, answer): self.answer = answer
            def run(self, argv, timeout=10): return (0 if self.answer == "enabled" else 1), self.answer
        os.environ.pop("USB16X16_STACK", None)
        self.assertEqual(apply_module.detect_stack(Enabled("enabled")), "dante")
        self.assertEqual(apply_module.detect_stack(Enabled("disabled")), "aes67")
        os.environ["USB16X16_STACK"] = "aes67"
        try:
            self.assertEqual(apply_module.detect_stack(Enabled("enabled")), "aes67")
        finally:
            del os.environ["USB16X16_STACK"]

    # ---- profile switches

    def test_switch_to_an_installed_preset_and_back(self):
        path = self.env.install("room", artifact())
        applier = self.make()
        result = applier.apply(self.request(profile="dante-room", expectedProfile="direct"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(self.env.conf_values(), {"METERS": "1", "DSP_PRESET": str(path), "DSP_SHA256": sha(artifact()), "DSP_LIVE": "1"})
        self.assertEqual(self.commands(), ["systemctl stop", "systemctl start"])
        self.assertEqual([s["name"] for s in result["steps"]], ["validating", "stopping", "switching", "starting", "verifying", "settling"])
        self.assertEqual(result["previousProfile"], "direct")
        self.assertEqual(result["live"], "dante-room")
        self.assertEqual(result["stack"], "dante")
        self.assertTrue(any(v.startswith("DSP loaded") for v in result["startLines"]["dante-room"]))
        self.assertTrue((self.env.spool / "receipts" / f"{result['id']}.json").exists())
        result = self.make().apply(self.request(profile="direct", expectedProfile="dante-room"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(self.env.conf_values(), {"METERS": "1"})

    def test_meters_setting_is_kept_across_a_switch(self):
        self.env.conf.write_text("METERS=0\n")
        self.env.install("room", artifact())
        self.assertEqual(self.make().apply(self.request(profile="dante-room"))["state"], "done")
        self.assertEqual(self.env.conf_values()["METERS"], "0")

    def test_refusals_change_nothing(self):
        self.env.install("room", artifact())
        before = self.env.conf.read_text()
        cases = [
            (dict(profile="direct"), "already the live profile"),
            (dict(profile="dante-missing"), "not installed"),
            (dict(profile="dsp-loaded"), "not installed"),
            (dict(profile="Dante Room"), "lower-case"),
            (dict(profile="dante-room", expectedProfile="dante-other"), "the page expected"),
            (dict(profile="dante-room", requestedAt=time.time() - 600), "old"),
            (dict(profile="dante-room", id="nothex"), "request id"),
            (dict(kind="reboot"), "unknown request kind"),
        ]
        for fields, expected in cases:
            result = self.make().apply(self.request(**fields))
            self.assertEqual(result["state"], "refused", fields)
            self.assertIn(expected, result["error"])
            self.assertEqual(self.commands(), [], fields)
        self.assertEqual(self.env.conf.read_text(), before)

    def test_an_installed_file_that_fails_the_guards_is_not_switched_to(self):
        self.env.install("bad", b"not an artifact\n")
        result = self.make().apply(self.request(profile="dante-bad"))
        self.assertEqual(result["state"], "refused")
        self.assertEqual(self.commands(), [])

    def test_missing_configuration_is_a_refusal(self):
        self.env.conf.unlink()
        result = self.make(runner=FakeRunnerNoConf()).apply(self.request(profile="direct"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("not installed", result["error"])

    def test_failed_start_rolls_back(self):
        self.env.install("room", artifact())
        before = self.env.conf.read_text()
        result = self.make(fail_start_for="dante-room").apply(self.request(profile="dante-room"))
        self.assertEqual(result["state"], "rolled-back")
        self.assertIn("failed", result["error"])
        self.assertEqual(self.env.conf.read_text(), before)
        self.assertEqual(self.commands(), ["systemctl stop", "systemctl start", "systemctl stop", "systemctl start"])
        self.assertEqual(result["live"], "direct")

    def test_fatal_line_during_settle_rolls_back(self):
        self.env.install("room", artifact())
        result = self.make(fatal_after_start_for="dante-room").apply(self.request(profile="dante-room"))
        self.assertEqual(result["state"], "rolled-back")
        self.assertIn("NETERROR", result["error"])
        self.assertEqual(self.env.live(), "direct")

    def test_a_restart_by_itself_during_settle_rolls_back(self):
        self.env.install("room", artifact())
        result = self.make(restart_during_settle_for="dante-room").apply(self.request(profile="dante-room"))
        self.assertEqual(result["state"], "rolled-back")
        self.assertIn("restarted by itself", result["error"])

    def test_streams_that_never_start_time_out_and_roll_back(self):
        self.env.install("room", artifact())
        result = self.make(never_netstart_for="dante-room").apply(self.request(profile="dante-room"))
        self.assertEqual(result["state"], "rolled-back")
        self.assertIn("not up within", result["error"])

    def test_rollback_that_also_fails_is_failed(self):
        self.env.install("a", artifact())
        self.env.install("b", artifact(0.5))
        self.assertEqual(self.make().apply(self.request(profile="dante-a"))["state"], "done")
        runner = FakeRunner(self.env, fail_start_for="dante-b")
        runner.fail_start_for = None
        applier = self.make(runner=runner)
        original_start = runner.run
        def failing(argv, timeout=60.0, env=None):
            if argv[:2] == ["systemctl", "start"]:
                runner.invocation += 1
                runner.unit = "failed"
                runner.log = ["FATAL the plugin's network threads did not appear"]
                return 0, ""
            return original_start(argv, timeout, env)
        runner.run = failing
        result = applier.apply(self.request(profile="dante-b"))
        self.assertEqual(result["state"], "failed")
        self.assertIn("rollback to dante-a also failed", result["error"])

    def test_a_configuration_the_wrapper_rejects_is_not_started(self):
        # The file changes between validation and the switch: the wrapper's hash check catches it.
        path = self.env.install("room", artifact())
        applier = self.make()
        original = applier.check_conf_text
        def tamper(text):
            path.write_bytes(artifact(0.25))
            return original(text)
        applier.check_conf_text = tamper
        result = applier.apply(self.request(profile="dante-room"))
        self.assertIn(result["state"], ("rolled-back", "failed"))
        self.assertIn("usb16x16-dante-start rejects", result["error"])
        self.assertEqual(self.env.live(), "direct")

    # ---- presets

    def test_preset_installs_and_switches(self):
        data = artifact(0.5, name="Room A")
        result = self.make().apply(self.with_artifact(data, kind="preset", name="Room A", slug="room-a", expectedProfile="direct"))
        self.assertEqual(result["state"], "done", result["error"])
        installed = self.env.dsp_dir / "dante-room-a.dsp"
        self.assertEqual(installed.read_bytes(), data)
        self.assertEqual(self.env.live(), "dante-room-a")
        self.assertEqual(self.env.conf_values()["DSP_SHA256"], sha(data))
        self.assertEqual(result["stats"]["biquads"], 0)
        self.assertTrue(any(c[0] == apply_module.OFFLINE_RUNNER for c in self.runner.calls), "load-checked first")
        self.assertFalse((self.env.spool / "presets" / result["request"]["artifactSha256"]).exists())

    def test_reapplying_the_live_slug_restarts_onto_the_new_file(self):
        self.assertEqual(self.make().apply(self.with_artifact(artifact(0.5), kind="preset", name="Room", slug="room"))["state"], "done")
        result = self.make().apply(self.with_artifact(artifact(0.25, inputs=8), kind="preset", name="Room", slug="room",
                                                      expectedProfile="dante-room"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(self.env.conf_values()["DSP_SHA256"], sha(artifact(0.25, inputs=8)))
        self.assertEqual(self.commands(), ["systemctl stop", "systemctl start"])

    def test_preset_refusals(self):
        good = artifact()
        cases = [
            (self.with_artifact(good, kind="preset", name="x", slug="Bad Slug"), "slug"),
            (self.with_artifact(good, kind="preset", name="x/y", slug="ok"), "preset name"),
            (self.with_artifact(b"junk", kind="preset", name="x", slug="ok"), "artifact"),
            ({**self.with_artifact(good, kind="preset", name="x", slug="ok"), "artifactSha256": "0" * 64}, "hash does not match"),
            (self.with_artifact(good, kind="preset", name="x", slug="ok", expectedProfile="dante-z"), "the page expected"),
        ]
        for request, expected in cases:
            result = self.make().apply(request)
            self.assertEqual(result["state"], "refused", expected)
            self.assertIn(expected, result["error"])
        self.assertEqual(list(self.env.dsp_dir.iterdir()), [])
        self.assertEqual(self.env.live(), "direct")

    def test_unstable_section_is_refused(self):
        text = artifact().decode().replace("branch 0\n", "branch 1\n0 1\n1 0 0 -2.5 1.2\n")
        result = self.make().apply(self.with_artifact(text.encode(), kind="preset", name="x", slug="ok"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("unstable", result["error"])

    def test_cap_and_remove(self):
        for index in range(apply_module.USER_PROFILE_CAP):
            self.env.install(f"p{index}", artifact())
        result = self.make().apply(self.with_artifact(artifact(), kind="preset", name="x", slug="one-more"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("remove one first", result["error"])
        result = self.make().apply(self.request(kind="remove", slug="p0"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertFalse((self.env.dsp_dir / "dante-p0.dsp").exists())
        self.assertEqual(self.commands(), [])

    def test_remove_refuses_the_live_preset_and_leaves_other_stacks_files(self):
        self.env.install("room", artifact())
        (self.env.dsp_dir / "user-room.dsp").write_bytes(artifact())     # an AES67 profile's file
        self.assertEqual(self.make().apply(self.request(profile="dante-room"))["state"], "done")
        result = self.make().apply(self.request(kind="remove", slug="room"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("live profile", result["error"])
        self.assertEqual(self.make().apply(self.request(profile="direct"))["state"], "done")
        self.assertEqual(self.make().apply(self.request(kind="remove", slug="room"))["state"], "done")
        self.assertTrue((self.env.dsp_dir / "user-room.dsp").exists())
        self.assertEqual(self.make().apply(self.request(kind="remove", slug="room"))["state"], "refused")

    # ---- live and commit

    def live_setup(self):
        self.assertEqual(self.make().apply(self.with_artifact(artifact(1.0), kind="preset", name="Room", slug="room"))["state"], "done")

    def test_live_update_then_commit(self):
        self.live_setup()
        runner = self.runner
        new = artifact(0.5)
        result = self.make(runner=runner).apply(self.with_artifact(new, kind="live", expectedProfile="dante-room"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual((self.env.run_dir / "dsp-live.dsp").read_bytes(), new)
        self.assertEqual(result["liveUpdate"]["sha256"], sha(new))
        self.assertEqual(self.env.conf_values()["DSP_SHA256"], sha(artifact(1.0)), "a live push installs nothing")
        self.assertEqual((self.env.dsp_dir / "dante-room.dsp").read_bytes(), artifact(1.0))
        before = len([c for c in runner.calls if c[:2] == ["systemctl", "start"]])
        result = self.make(runner=runner).apply(self.request(kind="commit", expectedProfile="dante-room", expectedLiveSha256=sha(new)))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(result["committed"], {"sha256": sha(new), "changed": True})
        self.assertEqual((self.env.dsp_dir / "dante-room.dsp").read_bytes(), new)
        self.assertEqual(self.env.conf_values(), {"METERS": "1", "DSP_PRESET": str(self.env.dsp_dir / "dante-room.dsp"),
                                                  "DSP_SHA256": sha(new), "DSP_LIVE": "1"})
        self.assertEqual(len([c for c in runner.calls if c[:2] == ["systemctl", "start"]]), before, "no restart")
        # and the committed pair is one the wrapper starts
        completed = subprocess.run([str(START), "--print"], capture_output=True, text=True,
                                   env={**os.environ, "USB16X16_DANTE_CONF": str(self.env.conf), "USB16X16_DSP_DIR": str(self.env.dsp_dir)})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        again = self.make(runner=runner).apply(self.request(kind="commit"))
        self.assertEqual(again["committed"]["changed"], False)

    def test_live_revert_pushes_the_installed_file(self):
        self.live_setup()
        runner = self.runner
        self.assertEqual(self.make(runner=runner).apply(self.with_artifact(artifact(0.5), kind="live"))["state"], "done")
        result = self.make(runner=runner).apply(self.request(kind="live", revert=True))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual((self.env.run_dir / "dsp-live.dsp").read_bytes(), artifact(1.0))

    def test_live_refusals(self):
        result = self.make().apply(self.with_artifact(artifact(), kind="live"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("nothing to update live", result["error"])
        self.live_setup()
        runner = self.runner
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.5, inputs=8), kind="live"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("shape differs", result["error"])
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.5), kind="live", expectedLiveSha256="f" * 64))
        self.assertEqual(result["state"], "refused")
        self.assertIn("the owner reports", result["error"])
        (self.env.dsp_dir / "dante-room.dsp").write_bytes(artifact(0.9))     # changed behind the pin
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.5), kind="live"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("does not hash to the pin", result["error"])
        self.assertFalse((self.env.run_dir / "dsp-live.dsp").exists())

    def test_live_needs_a_running_unit_and_live_following(self):
        self.live_setup()
        runner = self.runner
        runner.unit = "inactive"
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.5), kind="live"))
        self.assertIn("nothing is running", result["error"])
        runner.unit = "active"
        self.env.conf.write_text(self.env.conf.read_text().replace("DSP_LIVE=1\n", "DSP_LIVE=0\n"))
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.5), kind="live"))
        self.assertIn("DSP_LIVE=1", result["error"])

    def test_owner_that_does_not_answer_or_refuses_is_failed(self):
        self.live_setup()
        runner = self.runner
        runner.owner_ignores_live = True
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.5), kind="live"))
        self.assertEqual(result["state"], "failed")
        self.assertIn("the owner did not report", result["error"])
        runner.owner_ignores_live = False
        runner.owner_refuses_live = True
        result = self.make(runner=runner).apply(self.with_artifact(artifact(0.25), kind="live"))
        self.assertEqual(result["state"], "failed")
        self.assertIn("the owner refused", result["error"])

    def test_commit_with_nothing_applied_is_refused(self):
        self.live_setup()
        result = self.make(runner=self.runner).apply(self.request(kind="commit"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("nothing applied", result["error"])

    # ---- shutdown

    def test_shutdown_stops_the_dante_unit_and_powers_off(self):
        result = self.make().apply(self.request(kind="shutdown"))
        self.assertEqual(result["state"], "done")
        self.assertEqual(self.commands(), ["systemctl stop", "systemctl poweroff"])
        self.assertIn(["systemctl", "stop", "usb16x16-dante.service"], self.runner.calls)

    def test_consume_takes_the_request_file_and_the_artifact(self):
        request = self.with_artifact(artifact(0.5), kind="preset", name="Room", slug="room")
        (self.env.spool / "request.json").write_text(json.dumps(request))
        result = self.make().consume()
        self.assertEqual(result["state"], "done", result["error"])
        self.assertFalse((self.env.spool / "request.json").exists())
        self.assertFalse((self.env.spool / "presets" / request["artifactFile"]).exists())
        self.assertIsNone(self.make().consume())

    # ---- rates (SAMPLE_RATE_DESIGN.md, step 4d): one artifact per rate, the file for owner.conf's RATE run

    def test_owner_conf_carries_the_rate_and_48k_is_written_as_before(self):
        path = self.env.install("a", artifact())
        self.assertNotIn("RATE", apply_module.render_owner_conf("1", path, sha(artifact())))
        text = apply_module.render_owner_conf("1", self.env.dsp_dir / "dante-a@96000.dsp", "0" * 64, "96000")
        values = apply_module.parse_owner_conf(text)
        self.assertEqual(values["RATE"], "96000")
        self.assertEqual(apply_module.dante_profile_of(values), "dante-a", "the @rate suffix is not part of the profile")
        self.assertEqual(apply_module.running_rate({}), 48000)
        with self.assertRaises(apply_module.Refused):
            apply_module.running_rate({"RATE": "32000"})

    def test_artifacts_are_checked_at_their_own_rate(self):
        self.assertEqual(apply_module.parse_artifact(artifact(rate=96000).decode(), 96000)["rate"], 96000)
        with self.assertRaises(apply_module.Refused) as caught:
            apply_module.parse_artifact(artifact(rate=96000).decode())
        self.assertIn("compiled for rate 96000, expected 48000", str(caught.exception))
        # the delay ceiling is 10 ms at the artifact's rate
        long_delay = artifact(rate=96000).replace(b"\n0 0 1 0\n", b"\n0 960 1 0\n", 1)
        self.assertEqual(apply_module.parse_artifact(long_delay.decode(), 96000)["maxDelay"], 960)

    def test_a_preset_with_every_rate_installs_each_beside_the_48k_file(self):
        rates = {rate: artifact(0.5, rate=rate) for rate in (44100, 88200, 96000, 176400, 192000)}
        request = self.with_rates(self.with_artifact(artifact(0.5), kind="preset", name="Room", slug="room",
                                                     expectedProfile="direct"), rates)
        result = self.make().apply(request)
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual((self.env.dsp_dir / "dante-room.dsp").read_bytes(), artifact(0.5))
        for rate, data in rates.items():
            self.assertEqual((self.env.dsp_dir / f"dante-room@{rate}.dsp").read_bytes(), data)
        self.assertEqual(self.env.conf_values()["DSP_PRESET"], str(self.env.dsp_dir / "dante-room.dsp"), "48 kHz runs the 48 kHz file")
        self.assertNotIn("RATE", self.env.conf_values())
        checks = self.load_checks()
        self.assertEqual(len(checks), 6, "every rate is load-checked")
        self.assertNotIn("--rate", checks[0], "the 48 kHz check is the command line the installed runner knows")
        self.assertEqual(sorted(int(c[c.index("--rate") + 1]) for c in checks[1:]), sorted(rates))
        self.assertEqual(result["request"]["rates"], ["176400", "192000", "44100", "88200", "96000"])
        self.assertEqual(self.make().table()["dante-room"]["rates"], [44100, 48000, 88200, 96000, 176400, 192000])
        # A later version without 44.1 removes the old 44.1 file rather than keep other coefficients.
        request = self.with_rates(self.with_artifact(artifact(0.25), kind="preset", name="Room", slug="room",
                                                     expectedProfile="dante-room"), {96000: artifact(0.25, rate=96000)})
        self.assertEqual(self.make().apply(request)["state"], "done")
        self.assertFalse((self.env.dsp_dir / "dante-room@44100.dsp").exists())
        self.assertEqual((self.env.dsp_dir / "dante-room@96000.dsp").read_bytes(), artifact(0.25, rate=96000))
        # Removing the preset removes every rate.
        self.assertEqual(self.make().apply(self.request(profile="direct", expectedProfile="dante-room"))["state"], "done")
        self.assertEqual(self.make().apply(self.request(kind="remove", slug="room"))["state"], "done")
        self.assertEqual(list(self.env.dsp_dir.iterdir()), [])

    def test_rate_artifact_refusals_install_nothing(self):
        cases = [
            ({96000: artifact(rate=48000)}, "compiled for rate 48000, expected 96000"),
            ({48000: artifact()}, "not a rate this request can carry"),
            ({32000: artifact()}, "not a rate this request can carry"),
        ]
        for rates, expected in cases:
            result = self.make().apply(self.with_rates(self.with_artifact(artifact(), kind="preset", name="Room", slug="room"), rates))
            self.assertEqual(result["state"], "refused", rates)
            self.assertIn(expected, result["error"])
        request = self.with_rates(self.with_artifact(artifact(), kind="preset", name="Room", slug="room"), {96000: artifact(rate=96000)})
        request["rateArtifacts"]["96000"]["sha256"] = "0" * 64
        self.assertIn("does not hash", self.make().apply(request)["error"])
        request = self.with_rates(self.with_artifact(artifact(), kind="preset", name="Room", slug="room"), {96000: artifact(rate=96000)})
        request["rateArtifacts"]["96000"]["file"] = f"{request['id']}-44100.dsp"
        self.assertIn("must be <request id>-96000.dsp", self.make().apply(request)["error"])
        self.assertEqual(list(self.env.dsp_dir.iterdir()), [])
        self.assertEqual(self.commands(), [])

    def test_at_a_running_rate_the_switch_runs_that_rates_file(self):
        self.env.conf.write_text("METERS=1\nRATE=96000\n")
        self.env.install("room", artifact())
        at96 = self.env.dsp_dir / "dante-room@96000.dsp"
        at96.write_bytes(artifact(rate=96000))
        result = self.make().apply(self.request(profile="dante-room", expectedProfile="direct"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(self.env.conf_values(), {"METERS": "1", "RATE": "96000", "DSP_PRESET": str(at96),
                                                  "DSP_SHA256": sha(artifact(rate=96000)), "DSP_LIVE": "1"})
        self.assertEqual(self.env.live(), "dante-room")
        # A preset with no file for the running rate is refused, never run on 48 kHz coefficients.
        self.env.install("hall", artifact())
        result = self.make().apply(self.request(profile="dante-hall", expectedProfile="dante-room"))
        self.assertEqual(result["state"], "refused")
        self.assertIn("no artifact for 96000 Hz", result["error"])
        # And a new preset must carry the running rate.
        result = self.make().apply(self.with_artifact(artifact(), kind="preset", name="Club", slug="club"))
        self.assertIn("runs at 96000 Hz and the request carries no artifact for it", result["error"])

    def test_commit_rewrites_the_rates_it_carries_and_removes_the_stale_ones(self):
        request = self.with_rates(self.with_artifact(artifact(1.0), kind="preset", name="Room", slug="room"),
                                  {44100: artifact(1.0, rate=44100), 96000: artifact(1.0, rate=96000)})
        self.assertEqual(self.make().apply(request)["state"], "done")
        runner = self.runner
        new = artifact(0.5)
        self.assertEqual(self.make(runner=runner).apply(self.with_artifact(new, kind="live", expectedProfile="dante-room"))["state"], "done")
        commit = self.with_rates(self.request(kind="commit", expectedProfile="dante-room", expectedLiveSha256=sha(new)),
                                 {96000: artifact(0.5, rate=96000)})
        result = self.make(runner=runner).apply(commit)
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(result["committed"], {"sha256": sha(new), "changed": True})
        self.assertEqual(result["rates"], [48000, 96000])
        self.assertEqual((self.env.dsp_dir / "dante-room.dsp").read_bytes(), new)
        self.assertEqual((self.env.dsp_dir / "dante-room@96000.dsp").read_bytes(), artifact(0.5, rate=96000))
        self.assertFalse((self.env.dsp_dir / "dante-room@44100.dsp").exists(), "44.1 held the coefficients from before the edit")

    def test_consume_takes_the_rate_artifacts_too(self):
        request = self.with_rates(self.with_artifact(artifact(0.5), kind="preset", name="Room", slug="room"),
                                  {96000: artifact(0.5, rate=96000)})
        (self.env.spool / "request.json").write_text(json.dumps(request))
        self.assertEqual(self.make().consume()["state"], "done")
        self.assertEqual(list((self.env.spool / "presets").iterdir()), [])


class FakeRunnerNoConf:
    clock = time.time()
    calls = []
    def now(self): return self.clock
    def sleep(self, seconds): self.clock += seconds
    def run(self, argv, timeout=60.0, env=None):
        return 0, "active"


if __name__ == "__main__":
    unittest.main()
