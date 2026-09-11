"""Unit tests for the Apply half of usb16x16-web: the conf reader, the spool
state reader and the request writer. Run: python3 -m unittest work/web-control/test_web.py"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(apply_dir, conf_path):
    os.environ["USB16X16_APPLY_DIR"] = str(apply_dir)
    os.environ["USB16X16_AES67_CONF"] = str(conf_path)
    loader = importlib.machinery.SourceFileLoader("usb16x16_web", str(HERE / "usb16x16-web"))
    spec = importlib.util.spec_from_loader("usb16x16_web", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class WebApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = root / "web-apply"
        self.spool.mkdir()
        self.conf = root / "aes67.conf"
        self.conf.write_text('PROFILE=dsp-direct\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n'
                             'PROFILE_DSP_DIRECT_DESCRIPTION="no preset"\nPROFILE_FAST_STATUS=experimental\nPROFILE_FAST_TARGET=128\n')
        self.web = load(self.spool, self.conf)

    def tearDown(self):
        self.tmp.cleanup()

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
        (self.spool / "current.json").write_text(json.dumps({"state": "verifying", "updatedAt": now}))
        self.assertTrue(self.web.apply_state()["inFlight"])
        (self.spool / "current.json").write_text(json.dumps({"state": "done", "updatedAt": now}))
        self.assertFalse(self.web.apply_state()["inFlight"])
        stale = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
        (self.spool / "current.json").write_text(json.dumps({"state": "verifying", "updatedAt": stale}))
        self.assertFalse(self.web.apply_state()["inFlight"], "an abandoned operation does not block for ever")

    def test_pending_request_ages_out(self):
        request = self.spool / "request.json"
        request.write_text("{}")
        self.assertTrue(self.web.apply_state()["pending"])
        old = time.time() - 1000
        os.utime(request, (old, old))
        self.assertFalse(self.web.apply_state()["pending"])

    def test_write_request_is_atomic_and_well_formed(self):
        ident = self.web.write_apply_request("dsp-loaded", "dsp-direct", "bryan")
        body = json.loads((self.spool / "request.json").read_text())
        self.assertEqual(body["id"], ident)
        self.assertEqual(body["profile"], "dsp-loaded")
        self.assertEqual(body["expectedProfile"], "dsp-direct")
        self.assertEqual(body["requestedBy"], "bryan")
        self.assertAlmostEqual(body["requestedAt"], time.time(), delta=5)
        self.assertEqual(sorted(p.name for p in self.spool.iterdir()), ["request.json"], "no temp file left")

    def test_write_request_needs_the_spool(self):
        os.rmdir(self.spool)
        with self.assertRaises(PermissionError):
            self.web.write_apply_request("dsp-loaded", None, None)


if __name__ == "__main__":
    unittest.main()


class WebPresetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = root / "web-apply"
        (self.spool / "presets").mkdir(parents=True)
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
        body = json.loads((self.spool / "request.json").read_text())
        self.assertEqual(body["kind"], "preset")
        self.assertEqual(body["artifactFile"], f"{ident}.dsp")
        self.assertEqual((self.spool / "presets" / f"{ident}.dsp").read_bytes(), artifact)
        self.assertEqual(sorted(p.name for p in (self.spool / "presets").iterdir()), [f"{ident}.dsp"])


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
        spool = root / "web-apply"
        spool.mkdir()
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
