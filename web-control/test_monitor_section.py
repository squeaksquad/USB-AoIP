"""Tests for the bridge artifact's monitor section in the Python readers
(phase 3): usb16x16-apply's parse_artifact and artifact_shape and
usb16x16-web's artifact_shape refuse what DspStage::load refuses (the matrix
of dsp-core/tests/bridge_tests.cpp) and reproduce the pinned monitor shape
key; the applier refuses a section its engine binary does not know; the web
service reports control.monitor.engine and refuses a section early when it is
false. Run from the repo root:
python3 -m unittest web-control/test_monitor_section.py"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_web as base                    # noqa: E402  (modules, so their TestCases are not collected twice)
import test_apply as apply_tests           # noqa: E402
import test_dante_apply as dante_tests     # noqa: E402
import test_monitor as monitor_tests       # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
# One file for every implementation: bridge-artifact.test.mjs pins these bytes.
VECTOR = (REPO / "dsp-compiler/fixtures/pinned-monitor-vector.dsp").read_text()
MONITOR_KEY = "e119252efe5c29dceede375386fe80d48bb1596b6f206894408520f6c2e29694"
PLAIN_KEY = "7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0"
BASE = VECTOR[:VECTOR.index("monitor 1\n")] + "end\n"          # the old pinned vector
GOOD = VECTOR[VECTOR.index("monitor 1\n"):-len("end\n")]       # the section, without its end
# The default preset compiled in the fixed shape with the section on (node
# dsp-compiler/usb16x16-dsp-compile PRESET.json --shape fixed --bridge FILE,
# PRESET.json being model.mjs's createConfig()); its key is bridge-artifact.mjs's.
COMPILED = HERE / "fixtures/monitor-default.dsp"
COMPILED_KEY = "7bb5f3d0c57eb1fc18abffbaf42954299d35820644d293d6110f5e561c1a0263"
MARK = b"\x7fELF...dsp artifact: monitor: unexpected end..."

apply_module = apply_tests.apply_module


def with_section(artifact: str, section: str) -> str:
    end = artifact.rfind("end\n")
    return artifact[:end] + section + "end\n"


# bridge_tests.cpp, test_monitor_section_loader_refuses: each replacement of
# one piece of the section must be refused.
MUTATIONS = [
    ("monitor 1\n", "monitor 2\n"),
    ("monitor 1\n", "monitor 1 1\n"),
    ("monitor 1\n", "monitor\n"),
    ("sets 2\n", "sets 0\n"),
    ("sets 2\n", "sets 3\n"),
    ("sets 2\nset front speakers\nset cans headphones\n",
     "sets 9\nset a speakers\nset b speakers\nset c speakers\nset d speakers\nset e speakers\n"
     "set f speakers\nset g speakers\nset h speakers\nset i speakers\n"),
    ("set front speakers", "set Front speakers"),
    ("set front speakers", "set 1front speakers"),
    ("set front speakers", "set abcdefghijabcdefghijabcdefghijabc speakers"),
    ("set cans headphones", "set front headphones"),
    ("set cans headphones", "set cans monitors"),
    ("set cans headphones", "set cans headphones extra"),
    ("outs 3\n", "outs 4\n"),
    ("outs 3\n", "outs 17\n"),
    ("out 3 sub 0", "out 0 sub 0"),
    ("out 3 sub 0", "out 16 sub 0"),
    ("out 3 sub 0", "out 3 woofer 0"),
    ("out 3 sub 0", "out 3 sub"),
    ("out 3 sub 0", "out 3 sub 2"),
    ("out 3 sub 0", "out 3 sub 1"),
    ("out 3 sub 0", "out 03 sub +0"),
    ("out 0 speaker 0", "out 0 speaker 0 1"),
    ("out 3 sub 0", "out 3 sub 0 0"),
    ("label 3 Sub", "label 4 Sub"),
    ("label 3 Sub", "label 0 Sub"),
    ("label 3 Sub", "label 3 Sub\tWoofer"),
    ("label 3 Sub", "label 3 abcdefghijabcdefghijabcdefghijabc"),
    ("label 3 Sub", "label 3"),
    ("label 3 Sub", "label 3 Süb"),
    ("expandsets 2\n0\n-\n", "expandsets 1\n0\n"),
    ("expandsets 2\n0\n-\n", "expandsets 3\n0\n-\n0\n"),
    ("expandsets 2\n0\n-\n", "expandsets 2\n0\n2\n"),
    ("expandsets 2\n0\n-\n", "expandsets 2\n0\n- 1\n"),
    ("folds 2\n", "folds 3\n"),
    ("folds 2\n", "folds 9\n"),
    ("fold 0 stereo 2", "fold 1 stereo 2"),
    ("fold 0 stereo 2", "fold 2 stereo 2"),
    ("fold 0 stereo 2", "fold 0 full 2"),
    ("fold 0 stereo 2", "fold 0 Stereo 2"),
    ("fold 0 stereo 2", "fold 0 abcdefghijabcdefg 2"),
    ("fold 0 mono 3", "fold 0 stereo 3"),
    ("fold 0 stereo 2", "fold 0 stereo 0"),
    ("fold 0 stereo 2", "fold 0 stereo 3"),
    ("fold 0 stereo 2", "fold 0 stereo 257"),
    ("0 2 0.7071067811865476", "0 0 0.7071067811865476"),
    ("0 2 0.7071067811865476", "0 16 0.7071067811865476"),
    ("0 2 0.7071067811865476", "0 2 nan"),
    ("0 2 0.7071067811865476", "0 2 inf"),
    ("0 2 0.7071067811865476", "0 2 0x1p-1"),
    ("0 2 0.7071067811865476", "0 2 1e999"),
    ("0 2 0.7071067811865476", "0 2 1e-400"),
    ("0 2 0.7071067811865476", "0 2 1_0"),
    ("0 2 0.7071067811865476", "0 2 1e"),
    ("0 2 0.7071067811865476", "0 2 0.5 1"),
    ("3 3 1\n", "3 3 1\nend\n"),
    ("3 3 1\n", "3 3 1\nfold 0 x 1\n"),
]

FOUR = "monitor 1\nsets 1\nset s speakers\nouts 0\nexpandsets 2\n0\n0\nfolds 4\n" + "".join(
    f"fold 0 {name} 1\n0 0 1\n" for name in "abcd")
FIVE = FOUR.replace("folds 4", "folds 5") + "fold 0 e 1\n0 0 1\n"
SHARED = "monitor 1\nsets 2\nset a speakers\nset b speakers\nouts 1\nout 3 sub 0 1\nexpandsets 2\n0\n1\nfolds 0\n"
PHONES_SUB = "monitor 1\nsets 2\nset a speakers\nset b headphones\nouts 1\nout 3 sub 1\nexpandsets 2\n0\n1\nfolds 0\n"


class ReaderMatrixTests(unittest.TestCase):
    """The three readers against the C++ loader's matrix."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.web = base.load(base.make_spool(root), root / "aes67.conf")

    def tearDown(self):
        self.tmp.cleanup()

    def accepted(self, text: str) -> bool:
        """Whether all three readers take the text; they must agree."""
        try:
            apply_module.parse_artifact(text)
            parsed = True
        except apply_module.Refused:
            parsed = False
        try:
            apply_module.artifact_shape(text)
            shaped = True
        except apply_module.Refused:
            shaped = False
        web = self.web.artifact_shape(text) is not None
        self.assertEqual((parsed, shaped), (web, web), f"the readers disagree on:\n{text[-400:]}")
        return web

    def test_the_pinned_section_and_the_compiled_artifact_load(self):
        self.assertTrue(self.accepted(VECTOR))
        self.assertTrue(self.accepted(COMPILED.read_text()))
        self.assertEqual(apply_module.parse_artifact(VECTOR)["monitorSets"], 2)
        self.assertEqual(apply_module.parse_artifact(BASE)["monitorSets"], 0)

    def test_every_mutation_is_refused(self):
        for before, after in MUTATIONS:
            self.assertIn(before, GOOD, before)
            section = GOOD.replace(before, after, 1)
            self.assertFalse(self.accepted(with_section(BASE, section)), after)

    def test_the_counted_cases(self):
        self.assertFalse(self.accepted(BASE[:-len("end\n")] + GOOD), "a section with no end")
        self.assertTrue(self.accepted(with_section(BASE, FOUR)), "four folds in a set")
        self.assertFalse(self.accepted(with_section(BASE, FIVE)), "a fifth fold in a set")
        self.assertTrue(self.accepted(with_section(BASE, SHARED)), "a sub shared by two speaker sets")
        self.assertFalse(self.accepted(with_section(BASE, PHONES_SUB)), "a sub in a headphones set")
        self.assertFalse(self.accepted(BASE.replace("end\n", "mon1tor 1\nend\n")), "neither end nor monitor")

    def test_the_messages_name_the_line(self):
        section = GOOD.replace("set cans headphones", "set cans monitors")
        with self.assertRaisesRegex(apply_module.Refused, r"monitor: set kind must be speakers or headphones in 'set cans monitors'"):
            apply_module.parse_artifact(with_section(BASE, section))
        with self.assertRaisesRegex(apply_module.Refused, "monitor: unexpected end, expected end"):
            apply_module.parse_artifact(BASE[:-len("end\n")] + GOOD)

    def test_a_fold_gain_takes_part_in_the_applier_gain_bound(self):
        # The loader takes any finite gain; the applier bounds every gain at
        # +40 dB, and a fold row is a mix gain at the stage's input.
        loud = with_section(BASE, GOOD.replace("0 2 0.7071067811865476", "0 2 150"))
        with self.assertRaisesRegex(apply_module.Refused, "over \\+40 dB"):
            apply_module.parse_artifact(loud)
        self.assertIsNotNone(self.web.artifact_shape(loud), "the shape readers do not bound values")
        apply_module.parse_artifact(with_section(BASE, GOOD.replace("0 2 0.7071067811865476", "0 2 -100")))


class ShapeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.web = base.load(base.make_spool(root), root / "aes67.conf")

    def tearDown(self):
        self.tmp.cleanup()

    def keys(self, text):
        applier, web = apply_module.shape_key(text), self.web.shape_key(text)
        self.assertEqual(applier, web, "the applier and the web service agree")
        return applier

    def test_the_monitor_vector_is_pinned_and_without_it_the_old_one_holds(self):
        self.assertEqual(self.keys(VECTOR), MONITOR_KEY)
        self.assertEqual(self.keys(BASE), PLAIN_KEY)
        self.assertEqual(BASE, apply_tests.PINNED_VECTOR.replace("preset pinned shape vector", "preset pinned monitor vector"))

    def test_the_shape_is_every_section_line_but_the_labels_before_end(self):
        lines = [" ".join(line.split()) for line in GOOD.splitlines() if not line.startswith("label ")]
        expected = apply_module.artifact_shape(BASE)[:-len("end\n")] + "\n".join(lines) + "\nend\n"
        self.assertEqual(apply_module.artifact_shape(VECTOR), expected)
        self.assertEqual(self.web.artifact_shape(VECTOR), expected)

    def test_labels_and_spacing_are_not_shape_and_a_fold_gain_is(self):
        self.assertEqual(self.keys(VECTOR.replace("label 3 Sub", "label 3 Subwoofer")), MONITOR_KEY)
        self.assertEqual(self.keys(VECTOR.replace("out 3 sub 0", "out   3  sub 0")), MONITOR_KEY)
        self.assertEqual(self.keys(VECTOR.replace("outs 3\n", "\n   \nouts 3\n\n")), MONITOR_KEY, "blank lines are ignored")
        self.assertNotEqual(self.keys(VECTOR.replace("0 2 0.7071067811865476", "0 2 0.5")), MONITOR_KEY)

    def test_the_compiled_artifact_has_the_compilers_key(self):
        self.assertEqual(self.keys(COMPILED.read_text()), COMPILED_KEY)
        stripped = COMPILED.read_text()
        stripped = stripped[:stripped.index("\nmonitor 1\n") + 1] + "end\n"
        self.assertNotEqual(self.keys(stripped), COMPILED_KEY, "the section's presence is shape")


# ------------------------------------------------------------------ the applier: the engine guard

class AesEngineGuardTests(apply_tests.PresetFixture):
    """The AES67 applier: the bridge binary must know the section."""

    def applier(self, knows: bool):
        binary = Path(self.tmp.name) / "usb16x16-rt-bridge"
        binary.write_bytes(MARK if knows else b"\x7fELF an older bridge")
        return apply_module.Applier(inbox=self.env.inbox, state_dir=self.env.state, conf_path=self.env.conf,
                                    run_dir=self.env.run_dir, runner=apply_tests.PresetRunner(self.env),
                                    supervisor="/fake/supervisor", bridge_binary=binary,
                                    start_timeout=20.0, settle=5.0, poll=1.0)

    def test_a_compiled_artifact_with_a_section_installs_when_the_bridge_knows_it(self):
        self.preset_request(data=COMPILED.read_bytes())
        result = self.applier(True).consume()
        self.assertEqual(result["state"], "done", result)
        self.assertEqual(result["stats"]["monitorSets"], 1)
        self.assertEqual((self.dsp_dir / "user-room-a-night.dsp").read_bytes(), COMPILED.read_bytes())

    def test_and_is_refused_before_anything_when_it_does_not(self):
        self.preset_request(data=COMPILED.read_bytes())
        applier = self.applier(False)
        result = applier.consume()
        self.assertEqual(result["state"], "refused", result)
        self.assertIn("has a monitor section and the installed bridge", result["error"])
        self.assertEqual(applier.runner.calls, [], "nothing was run, not even the load check")
        self.assertEqual(list(self.dsp_dir.iterdir()), [])

    def test_an_artifact_without_one_is_not_affected(self):
        self.preset_request()
        self.assertEqual(self.applier(False).consume()["state"], "done")


class DanteEngineGuardTests(dante_tests.DanteFixture):
    """The Dante applier: the owner binary must know the section, on every
    path that hands an artifact to it. The offline runner's load check does
    not cover a new runner beside an older owner."""

    def setUp(self):
        super().setUp()
        self.saved_owner = dante_tests.apply_module.DANTE_OWNER
        self.owner = Path(self.directory.name) / "usb16x16-dante-owner"
        dante_tests.apply_module.DANTE_OWNER = self.owner
        self.compiled = COMPILED.read_bytes()

    def tearDown(self):
        dante_tests.apply_module.DANTE_OWNER = self.saved_owner
        super().tearDown()

    def owner_knows(self, knows: bool):
        self.owner.write_bytes(MARK if knows else b"\x7fELF owner c84e6a36")

    def regained(self, gain: str) -> bytes:
        """The compiled artifact with one expand gain changed: the same shape."""
        lines = self.compiled.decode().split("\n")
        at = next(i for i, line in enumerate(lines) if line.startswith("expand ")) + 1
        dest, source, _ = lines[at].split()
        lines[at] = f"{dest} {source} {gain}"
        return "\n".join(lines).encode()

    def install(self):
        return self.make().apply(self.with_artifact(self.compiled, kind="preset", name="Room", slug="room",
                                                    expectedProfile="direct"))

    def test_a_compiled_preset_with_a_section_installs_and_takes_live_edits(self):
        self.owner_knows(True)
        result = self.install()
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual((result["stats"]["monitorSets"], self.env.live()), (1, "dante-room"))
        runner = self.runner
        new = self.regained("0.5")
        self.assertNotEqual(new, self.compiled)
        self.assertEqual(apply_module.shape_key(new.decode()), COMPILED_KEY)
        result = self.make(runner=runner).apply(self.with_artifact(new, kind="live", expectedProfile="dante-room"))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(result["shape"], COMPILED_KEY)
        result = self.make(runner=runner).apply(self.request(kind="commit", expectedProfile="dante-room",
                                                             expectedLiveSha256=dante_tests.sha(new)))
        self.assertEqual((result["state"], result["committed"]["changed"]), ("done", True), result["error"])

    def test_an_older_owner_refuses_the_request_before_the_load_check_or_a_restart(self):
        for knows in (False, None):
            if knows is None:
                self.owner.unlink(missing_ok=True)      # unreadable counts as not knowing
            else:
                self.owner_knows(knows)
            result = self.install()
            self.assertEqual(result["state"], "refused", result)
            self.assertIn("has a monitor section and the installed owner", result["error"])
            self.assertEqual((self.commands(), self.load_checks()), ([], []))
            self.assertEqual(list(self.env.dsp_dir.iterdir()), [])
            self.assertEqual(self.env.live(), "direct")

    def test_a_section_in_another_rates_artifact_is_refused_the_same_way(self):
        self.owner_knows(False)
        request = self.with_artifact(dante_tests.artifact(), kind="preset", name="Room", slug="room")
        at96 = self.compiled.decode().replace("rate 48000\n", "rate 96000\n").replace("maxdelay 480\n", "maxdelay 960\n")
        self.with_rates(request, {96000: at96.encode()})
        result = self.make().apply(request)
        self.assertEqual(result["state"], "refused", result)
        self.assertIn("rateArtifacts 96000 has a monitor section", result["error"])

    def test_switching_to_an_installed_preset_after_the_owner_alone_rolled_back(self):
        self.owner_knows(True)
        self.assertEqual(self.install()["state"], "done")
        self.assertEqual(self.make().apply(self.request(profile="direct"))["state"], "done")
        self.owner_knows(False)                         # install-owner-*.sh rollback, the runner left new
        result = self.make().apply(self.request(profile="dante-room"))
        self.assertEqual(result["state"], "refused", result)
        self.assertIn("predates it", result["error"])
        self.assertEqual(self.commands(), [], "nothing stopped or started")
        self.assertEqual(self.env.live(), "direct")

    def test_a_live_edit_with_a_section_is_refused_by_an_older_owner(self):
        self.owner_knows(True)
        self.assertEqual(self.install()["state"], "done")
        runner = self.runner
        self.owner_knows(False)
        result = self.make(runner=runner).apply(self.with_artifact(self.regained("0.5"), kind="live",
                                                                   expectedProfile="dante-room"))
        self.assertEqual(result["state"], "refused", result)
        self.assertIn("predates it", result["error"])

    def test_the_mark_is_found_across_a_read_boundary(self):
        self.owner.write_bytes(b"\0" * ((1 << 20) - 5) + MARK)
        self.assertTrue(apply_module.binary_knows_monitor(self.owner))
        self.assertFalse(apply_module.binary_knows_monitor(Path(self.directory.name)), "a directory")


# ------------------------------------------------------------------ the web service: engine

class WebEngineTests(monitor_tests.MonitorServerCase):
    """control.monitor.engine and the early refusal on the artifact routes."""

    def post_route(self, route, body):
        return self.post(body, route=route)

    def test_health_carries_engine(self):
        control = self.web.monitor_control(True, {"dante": {"state": "active"}}, True)
        self.assertEqual((control["engine"], control["available"]), (True, True))
        idle = monitor_tests.status_text(sets=(), active="all", state="idle", seq="none")
        self.write_status(idle)
        control = self.web.monitor_control(True, {"dante": {"state": "active"}}, True)
        self.assertTrue(control["engine"], "an idle status with no sets: the engine knows the section")
        control = self.web.monitor_control(True, {"dante": {"state": "inactive"}}, True)
        self.assertEqual((control["engine"], control["available"]), (True, False), "the file, not the unit")
        self.write_status("MONITOR v=1 nonsense\n")
        self.assertFalse(self.web.monitor_control(True, {"dante": {"state": "active"}}, True)["engine"], "a file that does not parse")
        self.status_path.unlink()
        self.assertFalse(self.web.monitor_control(True, {"dante": {"state": "active"}}, True)["engine"], "no file")
        self.write_status(idle)
        self.assertFalse(self.web.monitor_control(False, {}, True)["engine"], "never on AES67")

    def test_a_preset_with_a_section_is_refused_without_the_engine(self):
        self.status_path.unlink()
        status, answer = self.post_route("/api/apply/preset", {"name": "Room", "artifact": VECTOR})
        self.assertEqual(status, 400, answer)
        self.assertIn("monitor section", answer["error"])
        self.assertEqual(self.requests(), [])
        status, answer = self.post_route("/api/apply/preset", {"name": "Room", "artifact": BASE,
                                                               "rateArtifacts": {"96000": VECTOR.replace("rate 48000", "rate 96000")}})
        self.assertEqual(status, 400, answer)
        self.assertIn("monitor section", answer["error"])
        status, answer = self.post_route("/api/apply/preset", {"name": "Room", "artifact": BASE})
        self.assertEqual(status, 202, answer)

    def test_with_the_engine_a_section_goes_through(self):
        status, answer = self.post_route("/api/apply/preset", {"name": "Room", "artifact": VECTOR})
        self.assertEqual(status, 202, answer)
        [request] = self.requests()
        self.assertEqual((self.inbox / request["artifactFile"]).read_text(), VECTOR)

    def test_live_and_commit_are_refused_the_same_way(self):
        self.status_path.unlink()
        status, answer = self.post_route("/api/apply/live", {"artifact": VECTOR})
        self.assertEqual(status, 400, answer)
        self.assertIn("monitor section", answer["error"])
        status, answer = self.post_route("/api/apply/commit", {"rateArtifacts": {"96000": VECTOR.replace("rate 48000", "rate 96000")}})
        self.assertEqual(status, 400, answer)
        self.assertIn("monitor section", answer["error"])
        status, answer = self.post_route("/api/apply/live", {"artifact": BASE})
        self.assertNotEqual(status, 400, "without a section the live gate decides")

    def test_the_section_line_is_what_is_looked_for(self):
        self.status_path.unlink()
        self.assertIsNone(self.web.monitor_section_refusal([BASE.replace("pinned monitor vector", "monitor desk")]))
        self.assertIsNotNone(self.web.monitor_section_refusal([VECTOR]))
        self.assertIsNotNone(self.web.monitor_section_refusal([VECTOR.replace("monitor 1\n", "monitor 1\r\n")]))


if __name__ == "__main__":
    unittest.main()
