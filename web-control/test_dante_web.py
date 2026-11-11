"""Unit tests for usb16x16-web on the Dante stack: what it reads (owner.conf,
installed presets, the owner's journal lines, its meter and live files) and
how the snapshot is shaped for the page.
Run: python3 -m unittest web-control/test_dante_web.py"""
import importlib.machinery
import importlib.util
import os
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

ARTIFACT = ("usb16x16-dsp 1\npreset Room A\nrate 48000\nchannels 16\ninternal 16\nmaxdelay 480\nexpand 16\n"
            + "".join(f"{c} {c} 1\n" for c in range(16)) + "branch 0\nassign 16\n"
            + "".join(f"{c} {c} 1\n" for c in range(16)) + "output 16\n"
            + "".join(f"{c} 0 1 0\n" for c in range(16)) + "end\n")

JOURNAL = """1791757664.000100 audio-dev usb16x16-dante[76423]: DSP t=1260.1 dsp_us_max=91.4 dsp_us_mean=79.5 dsp_calls=60012 dsp_resets=1 dsp_live_gen=2 dsp_live_applied=2 dsp_live_refused=0
1791757724.006241 audio-dev usb16x16-dante[76423]: OWNER t=1320.1 wakes=60024 gap_us_max=1018 tx_depth=78..81 rx_avail_max=49 tx_frames=2881159 rx_frames=2881159 tx_resyncs=0 tx_lost=0 rx_resyncs=0 rx_lost=0 cleared=1 offset_mismatches=0 net_errors=0
1791757724.006241 audio-dev usb16x16-dante[76423]: USB t=1320.1 usb=open tx=flow rx=flow tx_mean=128.0 rx_mean=144.0 rx_depth=95..109 pitch_c=1000015 pitch_p=1000015 tx_i=-14.54 rx_i=14.52 usb_tx=1 usb_rx=1 tx_links=1 tx_reprimes=0 rx_primes=1 rx_overflow=0 rx_idle_discards=0 capture_faults=0 playback_faults=0 detaches=0 pitch_write_errors=0 servo_rejected=0 out_peak=0,0 back_peak=0,0
1791757724.006241 audio-dev usb16x16-dante[76423]: METER t=1320.1 meter_us_max=7.6 meter_us_mean=4.4 meter_calls=120048
1791757725.000000 audio-dev usb16x16-dante[76423]: [2026-10-11T13:00:52Z WARN  inferno_aoip] something
"""


ENV_KEYS = ("USB16X16_APPLY_INBOX", "USB16X16_APPLY_STATE", "USB16X16_DANTE_CONF", "USB16X16_DANTE_RUN_DIR",
            "USB16X16_DSP_DIR", "USB16X16_STACK", "USB16X16_INFERNO_CONF", "USB16X16_STARTCHECK_STATUS",
            "USB16X16_STATIME_CONF", "USB16X16_CLOCK_STATE_FILE")


def load(root):
    os.environ["USB16X16_APPLY_INBOX"] = str(root / "inbox")
    os.environ["USB16X16_APPLY_STATE"] = str(root / "state")
    os.environ["USB16X16_DANTE_CONF"] = str(root / "owner.conf")
    os.environ["USB16X16_DANTE_RUN_DIR"] = str(root / "run")
    os.environ["USB16X16_DSP_DIR"] = str(root / "dsp")
    os.environ["USB16X16_STACK"] = "dante"
    os.environ["USB16X16_INFERNO_CONF"] = str(root / "asound-inferno-owner.conf")
    os.environ["USB16X16_STARTCHECK_STATUS"] = str(root / "startcheck-status")
    os.environ["USB16X16_STATIME_CONF"] = str(root / "statime.toml")
    os.environ["USB16X16_CLOCK_STATE_FILE"] = str(root / "port-state")
    loader = importlib.machinery.SourceFileLoader("usb16x16_web_dante", str(HERE / "usb16x16-web"))
    spec = importlib.util.spec_from_loader("usb16x16_web_dante", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class DanteWebTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name in ("inbox", "state", "run", "dsp"):
            (self.root / name).mkdir()
        (self.root / "owner.conf").write_text("# as installed\nMETERS=1\n")
        self.web = load(self.root)

    def tearDown(self):
        for key in ENV_KEYS:
            os.environ.pop(key, None)
        self.tmp.cleanup()

    def conf(self):
        return self.web.parse_owner_conf((self.root / "owner.conf").read_text())

    def test_stack_is_dante_and_words_follow(self):
        self.assertEqual(self.web.stack(), "dante")
        self.assertEqual(self.web.preset_prefix(), "dante-")
        self.assertEqual(self.web.words()["service"], "Dante service")
        self.assertNotIn("AES67", " ".join(self.web.words().values()))

    def test_direct_is_the_only_profile_as_installed(self):
        selected, rows = self.web.dante_profiles(self.conf())
        self.assertEqual(selected, "direct")
        self.assertEqual([r["name"] for r in rows], ["direct"])
        self.assertTrue(rows[0]["accepted"])
        self.assertFalse(rows[0]["user"])

    def test_installed_presets_are_user_rows_and_other_files_are_not(self):
        (self.root / "dsp" / "dante-room-a.dsp").write_text(ARTIFACT)
        (self.root / "dsp" / "user-room-a.dsp").write_text(ARTIFACT)      # an AES67 profile's
        (self.root / "dsp" / "loaded.dsp").write_text(ARTIFACT)
        (self.root / "dsp" / "dante-Bad Name.dsp").write_text(ARTIFACT)
        selected, rows = self.web.dante_profiles(self.conf())
        self.assertEqual([r["name"] for r in rows], ["direct", "dante-room-a"])
        row = rows[1]
        self.assertTrue(row["user"])
        self.assertFalse(row["accepted"])
        self.assertEqual(row["description"], "user preset: Room A")
        self.assertTrue(row["dspLive"], "an installed preset starts with live following on")
        self.assertIsNone(row["dspSha256"], "only the running preset has a pin to show")
        self.assertEqual(len(row["dspShape"]), 64)

    def test_the_running_preset_carries_the_configuration(self):
        path = self.root / "dsp" / "dante-room-a.dsp"
        path.write_text(ARTIFACT)
        (self.root / "owner.conf").write_text(f"METERS=1\nDSP_PRESET={path}\nDSP_SHA256={'a' * 64}\nDSP_LIVE=1\n")
        selected, rows = self.web.dante_profiles(self.conf())
        self.assertEqual(selected, "dante-room-a")
        self.assertEqual(rows[1]["dspSha256"], "a" * 64)
        self.assertTrue(rows[1]["dspLive"])
        (self.root / "owner.conf").write_text(f"METERS=1\nDSP_PRESET={path}\nDSP_SHA256={'a' * 64}\nDSP_LIVE=0\n")
        self.assertFalse(self.web.dante_profiles(self.conf())[1][1]["dspLive"])

    def test_rates_off_48k_name_the_running_file_and_list_each_presets_rates(self):
        """SAMPLE_RATE_DESIGN.md, steps 4 and 4d."""
        base = self.root / "dsp" / "dante-room-a.dsp"
        base.write_text(ARTIFACT)
        at96 = self.root / "dsp" / "dante-room-a@96000.dsp"
        at96.write_text(ARTIFACT.replace("rate 48000", "rate 96000").replace("maxdelay 480", "maxdelay 960"))
        selected, rows = self.web.dante_profiles(self.conf())
        self.assertEqual([r["name"] for r in rows], ["direct", "dante-room-a"], "the @rate file is not a preset of its own")
        self.assertEqual(rows[1]["rates"], [48000, 96000])
        (self.root / "owner.conf").write_text(f"METERS=1\nRATE=96000\nDSP_PRESET={at96}\nDSP_SHA256={'b' * 64}\nDSP_LIVE=1\n")
        selected, rows = self.web.dante_profiles(self.conf())
        self.assertEqual(selected, "dante-room-a", "the profile is the preset, whatever rate it runs at")
        self.assertEqual(rows[1]["dspShape"], self.web.installed_shape(str(at96)), "the running shape is the running file's")
        self.assertNotEqual(rows[1]["dspShape"], self.web.installed_shape(str(base)))

    def test_owner_lines(self):
        owner = self.web.parse_owner_lines(JOURNAL, now=1791757734.0)
        self.assertTrue(owner["present"])
        self.assertEqual(owner["ageSeconds"], 10.0)
        self.assertEqual(owner["loopGapUsMax"], 1018)
        self.assertEqual(owner["txDepth"], "78..81")
        self.assertEqual((owner["usb"], owner["usbOut"], owner["usbBack"]), ("open", "flow", "flow"))
        self.assertEqual((owner["txMean"], owner["rxMean"]), (128, 144))
        self.assertEqual((owner["ppmOut"], owner["ppmBack"]), (-14.54, 14.52))
        self.assertEqual((owner["captureFaults"], owner["playbackFaults"], owner["detaches"]), (0, 0, 0))
        self.assertEqual(owner["meterUsMax"], 7.6)
        self.assertIsNone(owner["dspUsMax"], "a DSP line from an earlier minute says nothing about now")
        self.assertEqual(self.web.parse_owner_lines("")["present"], False)
        self.assertEqual(self.web.parse_owner_lines("1.0 host x[1]: USB t=1 usb=open\n")["present"], False)

    def test_a_dsp_line_of_the_same_minute_is_reported(self):
        text = JOURNAL.replace("1791757664.000100", "1791757724.006241")
        owner = self.web.parse_owner_lines(text, now=1791757734.0)
        self.assertEqual((owner["dspUsMax"], owner["dspUsMean"], owner["dspLiveGen"]), (91.4, 79.5, 2))

    def test_meters_come_from_the_owners_file(self):
        self.assertIn("Dante endpoint", self.web.read_meters()["reason"])
        peaks = ",".join(["-20.0"] * 16)
        tap = lambda stage: f"TAP stage={stage} seq=3 frames=2400 position=7200 peak_dbfs={peaks} rms_dbfs={peaks} clip={','.join(['0'] * 16)}\n"
        (self.root / "run" / "meters.txt").write_text(
            "METERS v=1 t_us=1 window_frames=2400 writes=3\n" + tap("usb-capture") + tap("dante-playback") + tap("dante-capture"))
        meters = self.web.read_meters()
        self.assertTrue(meters["available"])
        self.assertEqual(meters["source"], "owner-tap")
        self.assertEqual(sorted(meters["taps"]), ["dante-capture", "dante-playback", "usb-capture"])
        self.assertIn("Dante out", meters["taps"]["dante-playback"]["where"])
        stale = self.web.read_meters(now=time.time() + 5)
        self.assertFalse(stale["available"])
        self.assertIn("no audio is moving", stale["reason"])

    def test_live_status_comes_from_the_owners_directory(self):
        self.assertIn("no preset is running", self.web.read_live_status()["reason"])
        (self.root / "run" / "dsp-live.status").write_text(f'DSPLIVE gen=2 sha256={"b" * 64} state=applied reason="" t_us=5\n')
        status = self.web.read_live_status()
        self.assertEqual((status["gen"], status["sha256"], status["state"]), (2, "b" * 64, "applied"))

    def test_snapshot_shape(self):
        collector = self.web.Collector(self.root, self.root)
        collector._slow = {"services": {"gadget": {"state": "active"}, "dante": {"state": "active"}, "statime": {"state": "active"}},
                           "profile": {"selected": "direct", "profiles": []}}
        collector._fast = collector.collect_fast()
        collector._daemon = {"owner": self.web.parse_owner_lines(JOURNAL)}
        collector._dsp = collector.collect_dsp()
        snapshot = collector.build()
        self.assertEqual(snapshot["stack"], "dante")
        self.assertTrue(snapshot["mode"]["running"])
        self.assertEqual(snapshot["mode"]["actual"], "direct")
        self.assertEqual(snapshot["mode"]["detail"], "USB ↔ Dante endpoint, direct")
        self.assertTrue(snapshot["owner"]["present"])
        self.assertNotIn("bridge", snapshot)
        self.assertNotIn("ptp", snapshot)
        self.assertNotIn("AES67", snapshot["dsp"]["reason"])
        collector._slow["profile"]["selected"] = "dante-room-a"
        snapshot = collector.build()
        self.assertEqual(snapshot["mode"]["actual"], "dsp")
        self.assertIn("dante-room-a", snapshot["mode"]["detail"])
        collector._slow["services"]["dante"]["state"] = "failed"
        snapshot = collector.build()
        self.assertFalse(snapshot["mode"]["running"])
        self.assertIn("Dante service failed", snapshot["mode"]["detail"])

    def snapshot(self, slow=None):
        collector = self.web.Collector(self.root, self.root)
        collector._slow = slow if slow is not None else {
            "services": {"gadget": {"state": "active"}, "dante": {"state": "active"}, "statime": {"state": "active"}},
            "profile": {"selected": "direct", "profiles": []}}
        collector._fast = collector.collect_fast()
        collector._daemon = {"owner": {"present": False}}
        return collector.build()

    def test_sample_rate_is_the_endpoints(self):
        slow = {"services": {}, "profile": {"selected": "direct", "profiles": [], "rate": 96000}}
        self.assertEqual(self.snapshot(slow)["audio"]["sampleRate"], 96000)
        slow["profile"]["rate"] = 44100
        self.assertEqual(self.snapshot(slow)["audio"], {"sampleRate": 44100, "inputs": 16, "outputs": 16})
        slow["profile"]["rate"] = None   # owner.conf's RATE= garbled
        self.assertEqual(self.snapshot(slow)["audio"]["sampleRate"], 48000)
        self.assertEqual(self.snapshot({"services": {}})["audio"]["sampleRate"], 48000, "before the slow tier ran")

    def test_device_name(self):
        text = ('# NAME "commented"\n</usr/share/alsa/alsa.conf>\npcm.inferno {\n\ttype inferno\n'
                '\tNAME "USB-AoIP Studio"\n\tDEVICE_ID "88a29e8b01e40000"\n}\n')
        self.assertEqual(self.web.parse_device_name(text), "USB-AoIP Studio")
        self.assertEqual(self.web.parse_device_name(None), "USB-AoIP")
        self.assertEqual(self.web.parse_device_name("pcm.inferno {\n}\n"), "USB-AoIP")
        self.assertEqual(self.web.parse_device_name('\tNAME ""\n'), "USB-AoIP")
        self.assertEqual(self.web.INFERNO_CONF, self.root / "asound-inferno-owner.conf")
        snapshot = self.snapshot()
        self.assertEqual(snapshot["device"], {"name": "USB-AoIP"}, "the default until the slow tier reads the file")
        slow = {"services": {}, "profile": {}, "device": {"name": "USB-AoIP Studio"}}
        self.assertEqual(self.snapshot(slow)["device"], {"name": "USB-AoIP Studio"})

    def test_start_check(self):
        parse = self.web.parse_startcheck
        self.assertEqual(parse("state=ok rate=6005 restarts=0 invocation=ab12 time=2026-11-01T12:00:00Z\n"),
                         {"state": "ok", "rate": 6005, "restarts": 0, "time": "2026-11-01T12:00:00Z"})
        self.assertEqual(parse("state=unknown rate= restarts=0 invocation= time=2026-11-01T12:00:00Z"),
                         {"state": "unknown", "rate": None, "restarts": 0, "time": "2026-11-01T12:00:00Z"})
        self.assertEqual(parse("state=gave-up rate=12 restarts=3 invocation=x time=yesterday")["time"], None)
        self.assertEqual(parse("state=restarting rate=12 restarts=x time=2026-11-01T12:00:00Z")["restarts"], None)
        nothing = {"state": "unknown", "rate": None, "restarts": None, "time": None}
        for garbled in (None, "", "garbage", "state=exploded rate=1", "state=ok\nstate=idle\n"):
            self.assertEqual(parse(garbled), nothing, repr(garbled))
        self.assertEqual(self.snapshot()["startCheck"], nothing, "no status file")
        (self.root / "startcheck-status").write_text("state=checking rate=6000 restarts=1 invocation=ab time=2026-11-01T12:00:00Z\n")
        self.assertEqual(self.snapshot()["startCheck"],
                         {"state": "checking", "rate": 6000, "restarts": 1, "time": "2026-11-01T12:00:00Z"})

    def test_clock(self):
        clock = self.web.clock_state
        for state in ("inactive", "failed", "activating"):
            self.assertEqual(clock(state, "warn")["state"], "no-leader", state)
        for state in (None, "unknown", ""):
            self.assertEqual(clock(state, "warn")["state"], "unknown", state)
        running = clock("active", "warn")
        self.assertEqual(running["state"], "unknown", "nothing Statime logs at warn shows lock")
        self.assertIn("warn", running["detail"])
        self.assertEqual(clock("active", "info")["state"], "unknown", "never a guessed lock")
        self.assertEqual(clock("active", None)["state"], "unknown")
        self.assertEqual(self.web.parse_statime_loglevel('# x\nloglevel = "warn"\nsdo-id = 0\n'), "warn")
        self.assertIsNone(self.web.parse_statime_loglevel(None))
        self.assertIsNone(self.web.parse_statime_loglevel("sdo-id = 0\n"))
        snapshot = self.snapshot()
        self.assertEqual(set(snapshot["clock"]), {"state", "detail"})
        self.assertEqual(snapshot["clock"]["state"], "unknown")

    def test_clock_from_a_published_port_state(self):
        clock, read = self.web.clock_state, self.web.read_port_state
        self.assertEqual(clock("active", "warn", ("Slave", "001dc1fffe0a0b0c0001", 300.0)),
                         {"state": "locked", "detail": "following leader 001dc1fffe0a0b0c0001"})
        self.assertEqual(clock("active", "warn", ("Slave", "", 1.0))["state"], "locked")
        self.assertEqual(clock("active", "warn", ("Master", "", 5.0))["state"], "no-leader")
        self.assertEqual(clock("active", "warn", ("Listening", "", 2.0))["state"], "unknown", "only just started")
        self.assertEqual(clock("active", "warn", ("Listening", "", 60.0))["state"], "no-leader")
        self.assertEqual(clock("active", "warn", ("Passive", "", 60.0))["state"], "unknown")
        self.assertEqual(clock("active", "warn", ("Faulty", "", 60.0))["state"], "unknown")
        # A stopped follower follows nothing, whatever an old file says.
        self.assertEqual(clock("inactive", "warn", ("Slave", "ab", 5.0))["state"], "no-leader")
        self.assertEqual(clock(None, "warn", ("Slave", "ab", 5.0))["state"], "unknown")
        path = self.root / "port-state"
        self.assertIsNone(read(path), "no file: a stock Statime")
        path.write_text("state=Slave port=1 leader=001dc1fffe0a0b0c0001\n")
        state, leader, age = read(path)
        self.assertEqual((state, leader), ("Slave", "001dc1fffe0a0b0c0001"))
        self.assertLess(age, 30)
        for garbled in ("", "state=Locked port=1 leader=\n", "nonsense", "state=\n"):
            path.write_text(garbled)
            self.assertIsNone(read(path), repr(garbled))
        path.write_text("state=Slave port=1 leader=$(reboot)\n")
        self.assertEqual(read(path)[:2], ("Slave", ""), "a leader that is not hex is dropped, not shown")
        path.write_text("state=Master port=1 leader=\n")
        self.assertEqual(read(path)[:2], ("Master", ""))
        slow = {"services": {"statime": {"state": "failed"}}, "profile": {}}
        self.assertEqual(self.snapshot(slow)["clock"]["state"], "no-leader")

    def test_existing_fields_are_still_there(self):
        snapshot = self.snapshot()
        for key in ("ok", "generated", "service", "host", "audio", "stack", "mode", "meters", "dsp", "owner",
                    "apply", "dspLive"):
            self.assertIn(key, snapshot)
        self.assertEqual(snapshot["service"]["version"], "1.7.0")

    def test_the_dante_dsp_answer_runs_no_engine_probe(self):
        collector = self.web.Collector(self.root, self.root)
        calls = []
        self.web.run = lambda argv, timeout=4.0: calls.append(argv)
        dsp = collector.collect_dsp()
        self.assertIsNone(dsp["engine"])
        self.assertEqual(calls, [])

    def test_log_units(self):
        self.assertIn("usb16x16-dante.service", self.web.DANTE_LOG_UNITS["all"])
        self.assertNotIn("usb16x16-aes67.service", sum(self.web.DANTE_LOG_UNITS.values(), []))


if __name__ == "__main__":
    unittest.main()
