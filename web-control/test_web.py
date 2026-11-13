"""Unit tests for usb16x16-web: the conf reader, the applier's inbox and state
readers, the request writer, and the HTTP surface (cross-site checks, security
headers, auth pages, bind and TLS). Run from the repo root:
python3 -m unittest web-control/test_web.py"""
import base64
import http.client
import io
import importlib.machinery
import importlib.util
import hashlib
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent


def load(spool, conf_path):
    """Load the service with the applier's inbox at <spool>/inbox and its
    state directory at <spool>/state."""
    os.environ["USB16X16_APPLY_INBOX"] = str(Path(spool) / "inbox")
    os.environ["USB16X16_APPLY_STATE"] = str(Path(spool) / "state")
    os.environ["USB16X16_AES67_CONF"] = str(conf_path)
    loader = importlib.machinery.SourceFileLoader("usb16x16_web", str(HERE / "usb16x16-web"))
    spec = importlib.util.spec_from_loader("usb16x16_web", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def make_spool(root):
    spool = Path(root) / "spool"
    (spool / "inbox").mkdir(parents=True)
    (spool / "state").mkdir()
    return spool


class WebApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = make_spool(root)
        self.inbox = self.spool / "inbox"
        self.state = self.spool / "state"
        self.conf = root / "aes67.conf"
        self.conf.write_text('PROFILE=dsp-direct\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n'
                             'PROFILE_DSP_DIRECT_DESCRIPTION="no preset"\nPROFILE_FAST_STATUS=experimental\nPROFILE_FAST_TARGET=128\n')
        self.web = load(self.spool, self.conf)

    def tearDown(self):
        self.tmp.cleanup()

    def request(self, ident):
        return json.loads((self.inbox / f"{ident}.request").read_text())

    def test_conf_profiles_accepted_first(self):
        rows = self.web.conf_profiles(self.web.parse_conf(self.conf.read_text()))
        self.assertEqual([r["name"] for r in rows], ["dsp-direct", "fast"])
        self.assertTrue(rows[0]["accepted"])
        self.assertEqual(rows[0]["description"], "no preset")
        self.assertIsNone(rows[0]["dspPreset"])

    def test_apply_state_empty(self):
        self.assertEqual(self.web.apply_state(), {"current": None, "pending": False, "inFlight": False})

    def test_apply_state_in_flight_and_terminal(self):
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        (self.state / "current.json").write_text(json.dumps({"state": "verifying", "updatedAt": now}))
        self.assertTrue(self.web.apply_state()["inFlight"])
        (self.state / "current.json").write_text(json.dumps({"state": "done", "updatedAt": now}))
        self.assertFalse(self.web.apply_state()["inFlight"])
        stale = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
        (self.state / "current.json").write_text(json.dumps({"state": "verifying", "updatedAt": stale}))
        self.assertFalse(self.web.apply_state()["inFlight"], "an abandoned operation does not block for ever")

    def test_current_json_is_read_from_the_state_directory_only(self):
        (self.inbox / "current.json").write_text(json.dumps({"state": "verifying"}))
        self.assertIsNone(self.web.apply_state()["current"])

    def test_pending_is_the_last_request_by_id_and_ages_out(self):
        self.assertFalse(self.web.apply_state()["pending"])
        (self.inbox / "0123456789abcdef.request").write_text("{}")
        self.assertFalse(self.web.apply_state()["pending"], "a name this process did not write is not looked for")
        ident = self.web.write_apply_request("dsp-loaded", None, "bryan")
        self.assertTrue(self.web.apply_state()["pending"])
        old = time.time() - 1000
        os.utime(self.inbox / f"{ident}.request", (old, old))
        self.assertFalse(self.web.apply_state()["pending"], "an old request no longer blocks")
        (self.inbox / f"{ident}.request").unlink()   # the applier picked it up
        self.assertFalse(self.web.apply_state()["pending"])

    def test_pending_never_lists_the_inbox(self):
        self.web.write_apply_request("dsp-loaded", None, "bryan")
        with mock.patch.object(self.web.os, "listdir", side_effect=AssertionError("listed")), \
             mock.patch.object(self.web.os, "scandir", side_effect=AssertionError("listed")), \
             mock.patch.object(self.web.Path, "iterdir", side_effect=AssertionError("listed")), \
             mock.patch.object(self.web.Path, "glob", side_effect=AssertionError("listed")):
            self.assertTrue(self.web.apply_state()["pending"])

    def test_write_request_is_atomic_and_well_formed(self):
        ident = self.web.write_apply_request("dsp-loaded", "dsp-direct", "bryan")
        body = self.request(ident)
        self.assertEqual(body["id"], ident)
        self.assertEqual(len(ident), 16)
        self.assertEqual(body["profile"], "dsp-loaded")
        self.assertEqual(body["expectedProfile"], "dsp-direct")
        self.assertEqual(body["requestedBy"], "bryan")
        self.assertAlmostEqual(body["requestedAt"], time.time(), delta=5)
        self.assertEqual(sorted(p.name for p in self.inbox.iterdir()), [f"{ident}.request"], "no temp file left")
        self.assertEqual((self.inbox / f"{ident}.request").stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.state.iterdir()), [], "nothing is written to the state directory")

    def test_each_request_has_its_own_id(self):
        first = self.web.write_apply_request("a", None, None)
        second = self.web.write_apply_request("b", None, None)
        self.assertNotEqual(first, second)
        self.assertEqual(sorted(p.name for p in self.inbox.iterdir()), sorted([f"{first}.request", f"{second}.request"]))

    def test_shutdown_request_is_written_as_its_kind(self):
        ident = self.web.write_apply_request("dsp-direct", None, "bryan", extra={"kind": "shutdown"})
        body = self.request(ident)
        self.assertEqual((body["id"], body["kind"], body["profile"], body["expectedProfile"], body["requestedBy"]),
                         (ident, "shutdown", "dsp-direct", None, "bryan"))
        self.assertNotIn("artifactFile", body)

    def test_write_request_needs_the_inbox(self):
        os.rmdir(self.inbox)
        self.assertIn("does not exist", self.web.inbox_unwritable())
        with self.assertRaises(PermissionError):
            self.web.write_apply_request("dsp-loaded", None, None)

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root can write anywhere")
    def test_an_unwritable_inbox_is_reported(self):
        self.assertIsNone(self.web.inbox_unwritable())
        os.chmod(self.inbox, 0o500)
        try:
            self.assertIn("not writable", self.web.inbox_unwritable())
            with self.assertRaises(PermissionError):
                self.web.write_apply_request("dsp-loaded", None, None)
        finally:
            os.chmod(self.inbox, 0o700)

    def test_a_tmp_name_in_the_way_is_not_followed_or_overwritten(self):
        with mock.patch.object(self.web.secrets, "token_hex", return_value="feedfacefeedface"):
            (self.inbox / "feedfacefeedface.request.tmp").write_text("someone else's")
            with self.assertRaises(FileExistsError):
                self.web.write_apply_request("x", None, None)
        self.assertEqual((self.inbox / "feedfacefeedface.request.tmp").read_text(), "someone else's")
        self.assertFalse((self.inbox / "feedfacefeedface.request").exists())


class WebPresetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = make_spool(root)
        self.inbox = self.spool / "inbox"
        self.conf = root / "aes67.conf"
        self.conf.write_text('PROFILE=dsp-direct\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n'
                             'PROFILE_USER_ROOM_STATUS=experimental\nPROFILE_USER_ROOM_TARGET=48\nPROFILE_USER_ROOM_DSP_PRESET=/etc/usb16x16/dsp/user-room.dsp\n')
        self.web = load(self.spool, self.conf)

    def tearDown(self):
        self.tmp.cleanup()

    def test_slugs(self):
        self.assertEqual(self.web.preset_slug("Room A · night"), "room-a-night")
        self.assertEqual(self.web.preset_slug("  --Weird__Name!!  "), "weird-name")
        self.assertEqual(self.web.preset_slug("x" * 40), "x" * 24)
        self.assertEqual(self.web.preset_slug("···"), "")

    def test_user_rows_are_flagged_and_ordered(self):
        rows = self.web.conf_profiles(self.web.parse_conf(self.conf.read_text()))
        self.assertEqual([(r["name"], r["user"]) for r in rows], [("dsp-direct", False), ("user-room", True)])

    def test_preset_request_writes_the_artifact_beside_it(self):
        artifact = b"usb16x16-dsp 1\npreset x\nend\n"
        ident = self.web.write_apply_request("user-x", "dsp-direct", "bryan",
                                             extra={"kind": "preset", "name": "x", "slug": "x", "artifactSha256": "ab"},
                                             artifact=artifact)
        body = json.loads((self.inbox / f"{ident}.request").read_text())
        self.assertEqual(body["kind"], "preset")
        self.assertEqual(body["artifactFile"], f"{ident}.dsp")
        self.assertEqual((self.inbox / f"{ident}.dsp").read_bytes(), artifact)
        self.assertEqual(sorted(p.name for p in self.inbox.iterdir()), [f"{ident}.dsp", f"{ident}.request"])
        for path in self.inbox.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o640, path.name)

    def test_preset_request_writes_every_rate_beside_it(self):
        rates = {"96000": b"usb16x16-dsp 1\npreset x\nrate 96000\nend\n", "44100": b"usb16x16-dsp 1\npreset x\nrate 44100\nend\n"}
        ident = self.web.write_apply_request("user-x", "dsp-direct", "bryan", extra={"kind": "preset"},
                                             artifact=b"usb16x16-dsp 1\nend\n", rate_artifacts=rates)
        body = json.loads((self.inbox / f"{ident}.request").read_text())
        self.assertEqual(body["rateArtifacts"], {
            rate: {"file": f"{ident}-{rate}.dsp", "sha256": hashlib.sha256(data).hexdigest()} for rate, data in rates.items()})
        for rate, data in rates.items():
            self.assertEqual((self.inbox / f"{ident}-{rate}.dsp").read_bytes(), data)
        self.assertEqual(len(list(self.inbox.iterdir())), 4, "no temporaries left")
        self.assertFalse((self.spool / "request.json").exists())

    def test_artifacts_are_renamed_into_place_before_the_request(self):
        rates = {"96000": b"usb16x16-dsp 1\nrate 96000\nend\n"}
        renames = []
        real = os.rename
        def record(source, target):
            renames.append((Path(source).name, Path(target).name))
            return real(source, target)
        with mock.patch.object(self.web.os, "rename", side_effect=record):
            ident = self.web.write_apply_request("user-x", None, "bryan", extra={"kind": "preset"},
                                                 artifact=b"usb16x16-dsp 1\nend\n", rate_artifacts=rates)
        self.assertEqual(renames, [(f"{ident}.dsp.tmp", f"{ident}.dsp"),
                                   (f"{ident}-96000.dsp.tmp", f"{ident}-96000.dsp"),
                                   (f"{ident}.request.tmp", f"{ident}.request")])

    def test_rate_artifacts_are_checked_for_form(self):
        text = "usb16x16-dsp 1\npreset x\nend\n"
        self.assertEqual(self.web.rate_artifacts_from({}, self.web.OTHER_RATES), {})
        self.assertEqual(self.web.rate_artifacts_from({"rateArtifacts": {"96000": text}}, self.web.OTHER_RATES),
                         {"96000": text.encode()})
        for given, reason in [({"48000": text}, "not a rate this request carries"), ({"32000": text}, "not a rate"),
                              ({"96000": "nonsense"}, "not the compiler's"), ({"96000": 5}, "not the compiler's"),
                              ({"96000": "usb16x16-dsp 1\n" + "x" * (1 << 18) + "end\n"}, "larger than"),
                              ("not a map", "must map")]:
            outcome = self.web.rate_artifacts_from({"rateArtifacts": given}, self.web.OTHER_RATES)
            self.assertIsInstance(outcome, str, given)
            self.assertIn(reason, outcome)
        self.assertEqual(self.web.rate_artifacts_from({"rateArtifacts": {"48000": text}}, self.web.DANTE_RATE_KEYS),
                         {"48000": text.encode()}, "a commit may carry 48 kHz")


METERS_TEXT = (
    "METERS v=1 t_us=123456 window_frames=2400 writes=7\n"
    "TAP stage=usb-capture seq=3 frames=2400 position=7200 peak_dbfs=" + ",".join(["-12.0"] * 16) +
    " rms_dbfs=" + ",".join(["-15.0"] * 16) + " clip=" + ",".join(["0"] * 16) + "\n"
    "TAP stage=ravenna-playback seq=3 frames=2448 position=7248 peak_dbfs=" + ",".join(["-6.0"] * 16) +
    " rms_dbfs=" + ",".join(["-9.0"] * 16) + " clip=" + ",".join(["4"] * 16) + "\n"
    "TAP stage=ravenna-capture seq=3 frames=2400 position=7200 peak_dbfs=" + ",".join(["-144.0"] * 16) +
    " rms_dbfs=" + ",".join(["-144.0"] * 16) + " clip=" + ",".join(["0"] * 16) + "\n"
    "TAP stage=usb-playback seq=3 frames=2400 position=7200 peak_dbfs=" + ",".join(["-144.0"] * 16) +
    " rms_dbfs=" + ",".join(["-144.0"] * 16) + " clip=" + ",".join(["0"] * 16) + "\n"
)


class MetersTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.run_dir = root / "run"
        self.run_dir.mkdir()
        os.environ["USB16X16_RUN_DIR"] = str(self.run_dir)
        spool = make_spool(root)
        conf = root / "aes67.conf"
        conf.write_text("PROFILE=dsp-direct\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n")
        self.web = load(spool, conf)

    def tearDown(self):
        os.environ.pop("USB16X16_RUN_DIR", None)
        self.tmp.cleanup()

    def test_parse_meters_reads_the_four_stages(self):
        body = self.web.parse_meters(METERS_TEXT)
        self.assertEqual(body["windowFrames"], 2400)
        self.assertEqual(body["writes"], 7)
        self.assertEqual(sorted(body["taps"]), ["ravenna-capture", "ravenna-playback", "usb-capture", "usb-playback"])
        out = body["taps"]["ravenna-playback"]
        self.assertEqual((out["sequence"], out["frames"], out["position"]), (3, 2448, 7248))
        self.assertEqual(out["peakDb"], [-6.0] * 16)
        self.assertEqual(out["rmsDb"], [-9.0] * 16)
        self.assertEqual(out["clipped"], [4] * 16)
        self.assertIn("after the DSP stage", out["where"])

    def test_parse_meters_refuses_what_it_cannot_read(self):
        self.assertIsNone(self.web.parse_meters(""))
        self.assertIsNone(self.web.parse_meters("BRIDGE ppm=1\n"))
        self.assertIsNone(self.web.parse_meters("METERS v=1\nTAP stage=usb-capture peak_dbfs=1,2 rms_dbfs=1,2 clip=0,0\n"))

    def test_read_meters_missing_stale_and_fresh(self):
        self.assertFalse(self.web.read_meters()["available"])
        self.assertIn("not running", self.web.read_meters()["reason"])
        path = self.run_dir / "meters"
        path.write_text(METERS_TEXT)
        fresh = self.web.read_meters()
        self.assertTrue(fresh["available"])
        self.assertEqual(fresh["windowMs"], 50.0)
        self.assertEqual(fresh["taps"]["usb-capture"]["peakDb"][0], -12.0)
        stale = self.web.read_meters(now=time.time() + 5)
        self.assertFalse(stale["available"])
        self.assertIn("stopped publishing", stale["reason"])
        path.write_text("garbage\n")
        self.assertFalse(self.web.read_meters()["available"])

    def test_health_fast_tier_reports_the_tap(self):
        collector = self.web.Collector(self.run_dir, self.run_dir)
        state = collector.collect_fast()
        self.assertFalse(state["meters"]["available"])
        self.assertEqual(state["meters"]["endpoint"], "/api/meters")
        (self.run_dir / "meters").write_text(METERS_TEXT)
        (self.run_dir / "last-bridge").write_text("BRIDGE ppm=-15.3 tx_queue=200 dsp_us_max=12.5 meter_us_max=1.25 rx_queue=100\n")
        state = collector.collect_fast()
        self.assertTrue(state["meters"]["available"])
        self.assertEqual(state["meters"]["stages"], ["ravenna-capture", "ravenna-playback", "usb-capture", "usb-playback"])
        self.assertEqual(state["bridge"]["meterUsMax"], 1.25)
        self.assertEqual(state["bridge"]["dspUsMax"], 12.5)


class WebLiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.run_dir = root / "run"
        self.run_dir.mkdir()
        os.environ["USB16X16_RUN_DIR"] = str(self.run_dir)
        self.spool = make_spool(root)
        self.inbox = self.spool / "inbox"
        self.conf = root / "aes67.conf"
        self.conf.write_text('PROFILE=user-room\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n'
                             'PROFILE_USER_ROOM_STATUS=experimental\nPROFILE_USER_ROOM_TARGET=48\n'
                             'PROFILE_USER_ROOM_DSP_PRESET=/etc/usb16x16/dsp/user-room.dsp\nPROFILE_USER_ROOM_DSP_LIVE=1\n')
        self.web = load(self.spool, self.conf)

    def tearDown(self):
        os.environ.pop("USB16X16_RUN_DIR", None)
        self.tmp.cleanup()

    def test_rows_carry_dsp_live(self):
        rows = {r["name"]: r for r in self.web.conf_profiles(self.web.parse_conf(self.conf.read_text()))}
        self.assertTrue(rows["user-room"]["dspLive"])
        self.assertFalse(rows["dsp-direct"]["dspLive"])

    def test_live_status_missing_and_present(self):
        status = self.web.read_live_status()
        self.assertFalse(status["available"])
        (self.run_dir / "dsp-live.status").write_text('DSPLIVE gen=7 sha256=abc state=applied reason="" t_us=99\n')
        status = self.web.read_live_status()
        self.assertTrue(status["available"])
        self.assertEqual((status["gen"], status["sha256"], status["state"], status["reason"]), (7, "abc", "applied", ""))
        self.assertLess(status["ageSeconds"], 5)
        (self.run_dir / "dsp-live.status").write_text('DSPLIVE gen=0 sha256=none state=idle reason="no live file yet" t_us=1\n')
        status = self.web.read_live_status()
        self.assertIsNone(status["sha256"])
        self.assertEqual(status["state"], "idle")

    def test_fast_tier_carries_the_live_fields(self):
        collector = self.web.Collector(self.run_dir, self.run_dir)
        (self.run_dir / "last-bridge").write_text("BRIDGE ppm=-15.3 tx_queue=200 dsp_live_gen=12 dsp_live_refused=0 rx_queue=100\n")
        (self.run_dir / "dsp-live.status").write_text('DSPLIVE gen=12 sha256=abc state=applied reason="" t_us=99\n')
        state = collector.collect_fast()
        self.assertEqual(state["bridge"]["dspLiveGen"], 12)
        self.assertEqual(state["dspLive"]["gen"], 12)
        self.assertEqual(state["dspLive"]["state"], "applied")

    def test_live_and_commit_requests_are_written_as_their_kinds(self):
        artifact = b"usb16x16-dsp 1\npreset x\nend\n"
        ident = self.web.write_apply_request("user-room", "user-room", "bryan",
                                             extra={"kind": "live", "artifactSha256": "ab", "expectedLiveSha256": None},
                                             artifact=artifact)
        body = json.loads((self.inbox / f"{ident}.request").read_text())
        self.assertEqual((body["kind"], body["profile"], body["artifactFile"]), ("live", "user-room", f"{ident}.dsp"))
        ident = self.web.write_apply_request("user-room", "user-room", "bryan",
                                             extra={"kind": "commit", "expectedLiveSha256": "ab"})
        body = json.loads((self.inbox / f"{ident}.request").read_text())
        self.assertEqual((body["kind"], body["expectedLiveSha256"]), ("commit", "ab"))
        self.assertNotIn("artifactFile", body)

    def test_shape_key_is_pinned_and_rows_carry_the_installed_shape(self):
        vector = ("usb16x16-dsp 1\npreset pinned shape vector\nrate 48000\nchannels 16\ninternal 2\nmaxdelay 480\n"
                  "expand 2\n0 0 0.125\n1 1 -0.5\nbranch 1\n1 2\n1 0 0 0 0\n0.5 0.25 0 -0.1 0.01\n"
                  "assign 2\n0 0 1\n3 1 0\noutput 16\n0 48 0.5 1\n1 0 0 0 0\n"
                  + "".join(f"{i} 0 1 0\n" for i in range(1, 16)) + "end\n")
        self.assertEqual(self.web.shape_key(vector), "7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0")
        self.assertIsNone(self.web.shape_key("not an artifact\n"))
        preset = Path(self.tmp.name) / "user-room.dsp"
        preset.write_text(vector)
        conf = self.conf.read_text().replace("/etc/usb16x16/dsp/user-room.dsp", str(preset)) + "PROFILE_USER_ROOM_DSP_SHA256=ab\n"
        rows = {r["name"]: r for r in self.web.conf_profiles(self.web.parse_conf(conf))}
        self.assertEqual(rows["user-room"]["dspShape"], "7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0")
        self.assertEqual(rows["user-room"]["dspSha256"], "ab")
        self.assertIsNone(rows["dsp-direct"]["dspShape"])

    def test_aes67_health_names_the_device_and_nothing_new_else(self):
        collector = self.web.Collector(self.run_dir, self.run_dir)
        collector._slow = {"services": {}}
        collector._fast = {}
        snapshot = collector.build()
        self.assertEqual(snapshot["stack"], "aes67")
        self.assertEqual(snapshot["device"], {"name": "USB-AoIP"})
        for key in ("startCheck", "clock"):
            self.assertNotIn(key, snapshot)

    def test_preset_store_accepts_the_shipped_name(self):
        self.assertTrue(self.web.PRESET_NAME.match("Immersive · stereo subs"))
        self.assertFalse(self.web.PRESET_NAME.match("../x"))


class ServerCase(unittest.TestCase):
    """A real server on 127.0.0.1, an ephemeral port, one user."""
    USER, PASSWORD = "tester", "correct horse"
    context = None

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = make_spool(root)
        self.static = root / "static"
        self.static.mkdir()
        (self.static / "index.html").write_text("<!doctype html><title>t</title>")
        conf = root / "aes67.conf"
        conf.write_text("PROFILE=dsp-direct\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n")
        self.web = load(self.spool, conf)
        auth = root / "web-auth"
        auth.write_text(f"{self.USER}:{self.web.PasswordFile.hash_password(self.PASSWORD, iterations=1000)}\n")
        self.presets_dir = root / "presets"
        handler = self.web.Handler
        handler.collector = self.web.Collector(self.static, self.presets_dir)
        handler.presets = self.web.PresetStore(self.presets_dir)
        handler.auth = self.web.Authenticator(self.web.PasswordFile(auth))
        handler.tls = self.context is not None
        handler.log_message = lambda *args: None
        self.server = self.web.make_server("127.0.0.1", 0, self.context)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.stderr = mock.patch.object(sys, "stderr", new=io.StringIO())
        self.stderr.start()

    def tearDown(self):
        self.stderr.stop()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def basic(self, password=None):
        token = base64.b64encode(f"{self.USER}:{password or self.PASSWORD}".encode()).decode()
        return {"Authorization": f"Basic {token}"}

    def connection(self):
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)

    def call(self, method, path, headers=None, body=None, auth=True, connection=None):
        own = connection is None
        connection = connection or self.connection()
        sent = dict(self.basic() if auth else {})
        sent.update(headers or {})
        connection.request(method, path, body=body, headers=sent)
        response = connection.getresponse()
        data = response.read()
        if own:
            connection.close()
        return response.status, response, data


CHANGE = {"X-USB-AoIP": "1", "Content-Type": "application/json"}


class CrossSiteTests(ServerCase):
    def put_preset(self, headers, body=b'{"outputs": []}'):
        return self.call("PUT", "/api/presets/Room", headers=headers, body=body)

    def test_header_and_json_without_origin_pass(self):
        status, _, data = self.put_preset(CHANGE)
        self.assertEqual(status, 200, data)
        self.assertTrue((self.presets_dir / "Room.json").exists())

    def test_matching_origin_passes(self):
        status, _, data = self.put_preset({**CHANGE, "Origin": f"http://127.0.0.1:{self.port}"})
        self.assertEqual(status, 200, data)
        status, _, data = self.put_preset({**CHANGE, "Origin": f"HTTP://127.0.0.1:{self.port}"})
        self.assertEqual(status, 200, "compared case-insensitively")

    def test_missing_header_is_refused(self):
        status, _, data = self.put_preset({"Content-Type": "application/json"})
        self.assertEqual(status, 403)
        body = json.loads(data)
        self.assertFalse(body["ok"])
        self.assertIn("X-USB-AoIP", body["error"])
        self.assertFalse((self.presets_dir / "Room.json").exists())
        status, _, _ = self.put_preset({"X-USB-AoIP": "0", "Content-Type": "application/json"})
        self.assertEqual(status, 403)

    def test_wrong_content_type_is_refused(self):
        for kind in ("text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", None):
            headers = {"X-USB-AoIP": "1"}
            if kind:
                headers["Content-Type"] = kind
            status, _, data = self.put_preset(headers)
            self.assertEqual(status, 403, kind)
            self.assertIn("application/json", json.loads(data)["error"])

    def test_foreign_origin_is_refused(self):
        for origin in ("http://evil.example", f"http://127.0.0.1:{self.port + 1}", "null", "http://localhost:" + str(self.port)):
            status, _, data = self.put_preset({**CHANGE, "Origin": origin})
            self.assertEqual(status, 403, origin)
            self.assertIn("Origin", json.loads(data)["error"])

    def test_every_changing_method_is_gated(self):
        for method, path in (("POST", "/api/apply/profile"), ("POST", "/api/apply/shutdown"),
                             ("DELETE", "/api/presets/Room"), ("DELETE", "/api/apply/preset/room"),
                             ("PUT", "/api/presets/Room")):
            status, _, _ = self.call(method, path, headers={"Content-Type": "application/json"}, body=b"{}")
            self.assertEqual(status, 403, f"{method} {path}")

    def test_no_body_needs_no_content_type(self):
        status, _, data = self.call("DELETE", "/api/presets/Nothing", headers={"X-USB-AoIP": "1"})
        self.assertEqual(status, 404, data)   # past the gate: the preset does not exist
        status, _, data = self.call("POST", "/api/apply/profile", headers={"X-USB-AoIP": "1"})
        self.assertEqual(status, 400, data)   # past the gate: no JSON object

    def test_auth_comes_first(self):
        status, _, _ = self.call("PUT", "/api/presets/Room", headers=CHANGE, body=b"{}", auth=False)
        self.assertEqual(status, 401)

    def test_a_refused_body_does_not_poison_the_connection(self):
        connection = self.connection()
        status, _, _ = self.call("PUT", "/api/presets/Room", headers={"Content-Type": "text/plain"},
                                 body=b'{"x": 1}', connection=connection)
        self.assertEqual(status, 403)
        status, _, _ = self.call("GET", "/api/presets", connection=connection)
        self.assertEqual(status, 200)
        connection.close()

    def test_options_is_refused_without_cors(self):
        status, response, _ = self.call("OPTIONS", "/api/apply/profile", auth=False,
                                        headers={"Origin": "http://evil.example",
                                                 "Access-Control-Request-Method": "POST",
                                                 "Access-Control-Request-Headers": "x-usb-aoip, content-type"})
        self.assertEqual(status, 405)
        self.assertFalse([name for name, _ in response.getheaders() if name.lower().startswith("access-control-")])


class HeaderAndAuthPageTests(ServerCase):
    def assert_security_headers(self, response):
        self.assertEqual(response.getheader("X-Content-Type-Options"), "nosniff")
        self.assertEqual(response.getheader("Referrer-Policy"), "no-referrer")
        self.assertEqual(response.getheader("X-Frame-Options"), "DENY")
        policy = response.getheader("Content-Security-Policy")
        self.assertIn("default-src 'self'", policy)
        self.assertIn("frame-ancestors 'none'", policy)
        self.assertIsNone(response.getheader("Strict-Transport-Security"), "no HSTS over plain HTTP")

    def test_security_headers_on_a_static_file_and_the_api(self):
        for path in ("/index.html", "/", "/api/health", "/api/no-such-thing"):
            status, response, _ = self.call("GET", path)
            self.assertIn(status, (200, 404), path)
            self.assert_security_headers(response)
        status, response, _ = self.call("GET", "/", auth=False)
        self.assertEqual(status, 401)
        self.assert_security_headers(response)

    def test_html_401_for_a_browser_and_json_for_the_page(self):
        status, response, data = self.call("GET", "/", auth=False, headers={"Accept": "text/html,application/xhtml+xml"})
        self.assertEqual(status, 401)
        self.assertEqual(response.getheader("WWW-Authenticate"), 'Basic realm="USB-AoIP control", charset="UTF-8"')
        self.assertTrue(response.getheader("Content-Type").startswith("text/html"))
        page = data.decode()
        self.assertIn("Reload", page)
        # The instruction must be one that runs on any unit: the installed program and the
        # login file this service was started with, not a script only a checkout has.
        self.assertIn("sudo usb16x16-web --auth-file ", page)
        self.assertIn(" --add-user NAME", page)
        self.assertNotIn("install.sh", page)
        self.assertIn("Safari, Chrome or Firefox", page)
        self.assertNotIn("http://", page.replace('"http://www.w3.org', ""), "no external resources")
        self.assertNotIn("<script", page)
        status, response, data = self.call("GET", "/api/health", auth=False, headers={"Accept": "application/json"})
        self.assertEqual(status, 401)
        self.assertTrue(response.getheader("Content-Type").startswith("application/json"))
        self.assertFalse(json.loads(data)["ok"])

    def test_wrong_password_page(self):
        status, response, data = self.call("GET", "/", auth=False,
                                           headers={**self.basic("wrong password"), "Accept": "text/html"})
        self.assertEqual(status, 401)
        self.assertIn("Wrong user name or password", data.decode())
        status, response, data = self.call("GET", "/api/health", auth=False, headers=self.basic("wrong password"))
        self.assertEqual(json.loads(data)["error"], "Wrong user name or password")

    def test_too_many_attempts_page(self):
        for _ in range(self.web.FAIL_LIMIT):
            self.web.Handler.auth.note_failure("127.0.0.1")
        status, response, data = self.call("GET", "/", auth=False,
                                           headers={**self.basic("wrong password"), "Accept": "text/html"})
        self.assertEqual(status, 429)
        self.assertTrue(response.getheader("Content-Type").startswith("text/html"))
        self.assertIn("Wait a minute", data.decode())
        status, response, data = self.call("GET", "/api/health", auth=False, headers=self.basic("wrong password"))
        self.assertEqual(status, 429)
        self.assertIn("wait a minute", json.loads(data)["error"])

    def test_handler_has_a_socket_timeout(self):
        self.assertEqual(self.web.Handler.timeout, 30)


    def test_the_sign_in_page_names_the_login_file_it_runs_with(self):
        self.web.Handler.auth_file = "/etc/usb-aoip/web-auth"
        _, _, data = self.call("GET", "/", auth=False, headers={"Accept": "text/html"})
        self.assertIn("sudo usb16x16-web --auth-file /etc/usb-aoip/web-auth --add-user NAME", data.decode())
        self.web.Handler.auth_file = '/tmp/a<b>&"c'
        _, _, data = self.call("GET", "/", auth=False, headers={"Accept": "text/html"})
        self.assertIn("/tmp/a&lt;b&gt;&amp;&quot;c", data.decode())
        self.assertNotIn("a<b>", data.decode())

    def test_adding_a_login_keeps_who_may_read_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "web-auth"
            store = self.web.PasswordFile(path)
            store.set_user("first", "a-long-password")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, "a new file is the caller's alone")
            os.chmod(path, 0o640)   # as installed: root's, readable by the service's group
            store.set_user("second", "another-password")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640, "the group can still read it")
            self.assertEqual(sorted(store.load()), ["first", "second"])
            os.chmod(path, 0o644)
            store.remove_user("second")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640, "never wider than owner and group")
            self.assertEqual(sorted(store.load()), ["first"])


class BindTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.static = root / "static"
        self.static.mkdir()
        (self.static / "index.html").write_text("x")
        self.web = load(make_spool(root), root / "aes67.conf")

    def tearDown(self):
        self.tmp.cleanup()

    def main(self, *argv):
        with mock.patch.object(sys, "argv", ["usb16x16-web", "--static", str(self.static), "--no-auth",
                                             "--presets", str(Path(self.tmp.name) / "p"), *argv]), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            return self.web.main()

    def test_choose_bind(self):
        self.assertEqual(self.web.choose_bind("127.0.0.1", "wlan0", lookup=lambda name: "10.0.0.5"), "127.0.0.1")
        self.assertEqual(self.web.choose_bind("", "wlan0", lookup=lambda name: "10.0.0.5"), "10.0.0.5")
        self.assertIsNone(self.web.choose_bind("", "wlan0", lookup=lambda name: None), "no loopback fallback")

    def test_exit_75_when_the_interface_has_no_address(self):
        self.assertEqual(self.main("--management-interface", "aoipnone9"), 75)

    def test_tls_options_go_together_and_must_be_readable(self):
        self.assertEqual(self.main("--bind", "127.0.0.1", "--tls-cert", "/nonexistent/cert.pem"), 2)
        self.assertEqual(self.main("--bind", "127.0.0.1", "--tls-cert", "/nonexistent/c.pem",
                                   "--tls-key", "/nonexistent/k.pem"), 2)


@unittest.skipUnless(shutil.which("openssl"), "the openssl CLI is needed to make a throwaway certificate")
class TlsTests(ServerCase):
    def setUp(self):
        self.certdir = tempfile.TemporaryDirectory()
        cert, key = Path(self.certdir.name) / "cert.pem", Path(self.certdir.name) / "key.pem"
        made = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                               "-out", str(cert), "-days", "1", "-subj", "/CN=127.0.0.1"],
                              capture_output=True, timeout=60)
        if made.returncode != 0:
            self.skipTest(f"openssl could not make a certificate: {made.stderr[-200:]!r}")
        loader_module = load(Path(self.certdir.name), Path(self.certdir.name) / "none.conf")
        self.context = loader_module.tls_context(str(cert), str(key))
        super().setUp()

    def tearDown(self):
        super().tearDown()
        self.certdir.cleanup()

    def https(self):
        client = ssl.create_default_context()
        client.check_hostname = False
        client.verify_mode = ssl.CERT_NONE
        return http.client.HTTPSConnection("127.0.0.1", self.port, timeout=5, context=client)

    def test_https_request_and_hsts(self):
        status, response, data = self.call("GET", "/api/health", connection=self.https())
        self.assertEqual(status, 200, data)
        self.assertEqual(response.getheader("Strict-Transport-Security"), "max-age=31536000")
        self.assertEqual(response.getheader("X-Content-Type-Options"), "nosniff")

    def test_a_stalled_handshake_does_not_block_another_client(self):
        stalled = socket.create_connection(("127.0.0.1", self.port))
        try:
            time.sleep(0.2)   # accepted, and waiting in its own thread for a ClientHello that never comes
            started = time.monotonic()
            status, _, _ = self.call("GET", "/api/health", connection=self.https())
            self.assertEqual(status, 200)
            self.assertLess(time.monotonic() - started, 4)
        finally:
            stalled.close()

    def test_plain_http_to_the_tls_port_is_just_closed(self):
        plain = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            plain.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            self.assertEqual(plain.recv(1024), b"", "the connection is closed, nothing is served")
        except ConnectionResetError:
            pass
        finally:
            plain.close()
        status, _, _ = self.call("GET", "/api/health", connection=self.https())
        self.assertEqual(status, 200, "the server is still serving")


if __name__ == "__main__":
    unittest.main()
