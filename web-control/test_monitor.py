"""Tests for the monitor block (phase 3): usb16x16-web 1.9.0's state file,
its strict parsers for the three files of docs/web/MONITOR-FILES.md, the
remembered copy's debounce, GET and POST /api/monitor, the two apply routes;
and usb16x16-apply 1.11.0's monitor-limits and monitor-reference kinds and
its modinfo fallback for the support bundle.
Run from the repo root: python3 -m unittest web-control/test_monitor.py"""
import io
import json
import os
import re
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_web as base            # noqa: E402  (modules, so their TestCases are not collected twice)
import test_apply as apply_tests   # noqa: E402
import test_dante_apply as dante_tests   # noqa: E402

CHANGE = base.CHANGE
REPO = Path(__file__).resolve().parent.parent
CONTRACT = REPO / "docs/web/MONITOR-FILES.md"
ZEROS = ",".join(["0"] * 16)


def contract_examples():
    """The three example files of MONITOR-FILES.md, in order: state, limits, status."""
    text = CONTRACT.read_text()
    blocks = re.findall(r"### Example\n\n```\n(.*?)```", text, re.S)
    assert len(blocks) == 3, len(blocks)
    return blocks


def status_text(sets=(("mains", "speakers", "full,stereo,mono"), ("phones", "headphones", "full,mono")),
                state="applied", seq="7", active="mains", outs=None):
    lines = [f'MONITOR v=1 gen=3 seq={seq} state={state} reason="" t_us=123456', f"active={active}", "dim_db=-20.0 subs=on"]
    for ident, kind, folds in sets:
        lines.append(f"set id={ident} kind={kind} level_db=-30.0 trim_db=0.0 dim=0 mute=0 fold=full folds={folds} gain_db=-30.0")
    if outs is None:
        outs = [f'out n={i} set={sets[0][0]} role=speaker label="Out {i + 1}"' for i in range(2)] if sets else []
    lines += outs
    lines += [f"solo={ZEROS} mute={ZEROS}", "end"]
    return "\n".join(lines) + "\n"


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class FormatTests(unittest.TestCase):
    """The parsers and writers, against the contract's own examples."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.web = base.load(base.make_spool(root), root / "aes67.conf")
        self.state_example, self.limits_example, self.status_example = contract_examples()

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_contracts_examples_parse_and_the_state_renders_back_byte_for_byte(self):
        seq, state = self.web.parse_monitor_state(self.state_example)
        self.assertEqual((seq, state["active"], list(state["sets"])), (42, "mains", ["mains", "nearfield", "phones"]))
        self.assertEqual(state["sets"]["nearfield"], {"levelDb": -24.0, "trimDb": -1.5, "dim": False, "mute": False,
                                                      "fold": "stereo"})
        self.assertEqual(state["outMute"], [False] * 14 + [True, True])
        self.assertEqual(self.web.render_monitor_state(seq, state), self.state_example)
        limits = self.web.parse_monitor_limits(self.limits_example)
        self.assertEqual((limits["maxDb"], limits["start"], limits["lock"]), (-6.0, "reference", True))
        self.assertEqual(limits["startDb"], -30.0)
        clamped = self.web.parse_monitor_limits(self.limits_example.replace("start_db=-30.0", "start_db=-1.0"))
        self.assertEqual(clamped["startDb"], -6.0, "start_db clamped to max_db by the reader")
        self.assertEqual(limits["refs"]["mains"], {"levelDb": -18.0, "note": "79 dB SPL C at the desk"})
        status = self.web.parse_monitor_status(self.status_example)
        self.assertEqual([s["id"] for s in status["sets"]], ["mains", "nearfield", "phones"])
        topology = self.web.monitor_topology(status)
        self.assertEqual([o["n"] for o in topology["sets"][1]["outputs"]], [4, 5, 3], "the shared sub is in both sets")
        self.assertEqual(self.web.monitor_effective(status)["sets"]["mains"]["gainDb"], -18.5)

    def test_the_applier_reads_and_writes_the_limits_the_same_way(self):
        limits = apply_tests.apply_module.parse_monitor_limits(self.limits_example)
        self.assertEqual(limits, self.web.parse_monitor_limits(self.limits_example))
        raw = self.limits_example.replace("start_db=-30.0", "start_db=-36.0")
        self.assertEqual(apply_tests.apply_module.render_monitor_limits(apply_tests.apply_module.parse_monitor_limits(raw)),
                         raw, "a file already within its limits renders back byte for byte")

    def test_state_round_trip_keeps_numbers_to_one_decimal(self):
        state = self.web.empty_monitor_state()
        state["sets"]["a"] = {"levelDb": -0.04, "trimDb": 11.96, "dim": True, "mute": False, "fold": "5.1"}
        state["active"] = "a"
        text = self.web.render_monitor_state(9, state)
        self.assertIn("set id=a level_db=0.0 trim_db=12.0 dim=1 mute=0 fold=5.1\n", text, "never -0.0")
        self.assertEqual(self.web.parse_monitor_state(text)[1]["sets"]["a"]["levelDb"], 0.0)

    def test_hostile_state_files_are_refused(self):
        good = self.state_example
        many = good.replace("solo=", "".join(f"set id=s{i} level_db=-1.0 trim_db=0.0 dim=0 mute=0 fold=full\n"
                                              for i in range(14)) + "solo=")
        cases = {
            "no end": good.replace("end\n", ""),
            "after end": good + "set id=x level_db=0.0 trim_db=0.0 dim=0 mute=0 fold=full\n",
            "no final newline": good[:-1],
            "nan": good.replace("dim_db=-20.0", "dim_db=nan"),
            "inf": good.replace("level_db=-18.5", "level_db=inf"),
            "exponent": good.replace("level_db=-18.5", "level_db=-1e1"),
            "no decimal": good.replace("level_db=-18.5", "level_db=-18"),
            "two decimals": good.replace("level_db=-18.5", "level_db=-18.55"),
            "out of range": good.replace("level_db=-18.5", "level_db=0.5"),
            "trim out of range": good.replace("trim_db=-1.5", "trim_db=-12.1"),
            "upper-case id": good.replace("id=mains", "id=Mains"),
            "digit first": good.replace("id=mains", "id=1mains"),
            "long id": good.replace("id=phones", "id=" + "p" * 33),
            "bad fold": good.replace("fold=stereo", "fold=Stereo"),
            "duplicate set": good.replace("id=nearfield", "id=mains"),
            "17 sets": many,
            "active not listed": good.replace("active=mains", "active=sub"),
            "order": good.replace("dim_db=-20.0\nsubs=on\n", "subs=on\ndim_db=-20.0\n"),
            "carriage return": good.replace("\n", "\r\n"),
            "15 flags": good.replace("solo=" + ZEROS, "solo=" + ",".join(["0"] * 15)),
            "a 2 flag": good.replace("solo=0,", "solo=2,"),
            "extra space": good.replace("dim=0 mute=0 fold=full", "dim=0  mute=0 fold=full", 1),
            "unknown key": good.replace("fold=full\n", "fold=full gain=1\n", 1),
            "version 2": good.replace("v=1", "v=2"),
            "seq not a number": good.replace("seq=42", "seq=-1"),
        }
        self.assertEqual(len(self.web.parse_monitor_state(many.replace("set id=s13 level_db=-1.0 trim_db=0.0 dim=0 mute=0 fold=full\n", ""))[1]["sets"]), 16,
                         "sixteen sets are allowed")
        for name, text in cases.items():
            with self.assertRaises(ValueError, msg=name):
                self.web.parse_monitor_state(text)

    def test_hostile_status_files_are_refused(self):
        good = status_text()
        self.web.parse_monitor_status(good)
        cases = {
            "fold not offered": good.replace("fold=full folds=full,mono", "fold=stereo folds=full,mono"),
            "folds without full": good.replace("folds=full,mono", "folds=mono"),
            "repeated fold": good.replace("folds=full,mono", "folds=full,full"),
            "out for an unknown set": good.replace("set=mains role", "set=nobody role", 1),
            "output 16": good.replace("out n=0 ", "out n=16 "),
            "repeated output": good.replace("out n=1 ", "out n=0 "),
            "gain inf": good.replace("gain_db=-30.0", "gain_db=inf", 1),
            "quote in label": good.replace('label="Out 1"', 'label="Out "1"'),
            "backslash in label": good.replace('label="Out 1"', 'label="Out \\1"'),
            "unknown state": good.replace("state=applied", "state=running"),
            "no end": good.replace("end\n", ""),
        }
        moved = good.split("\n")
        moved.insert(3, moved.pop(5))      # an out line between the set lines
        cases["out between sets"] = "\n".join(moved)
        for name, text in cases.items():
            with self.assertRaises(ValueError, msg=name):
                self.web.parse_monitor_status(text)
        muted = self.web.parse_monitor_status(good.replace("gain_db=-30.0", "gain_db=-inf", 1))
        self.assertIsNone(muted["sets"][0]["gainDb"])
        self.assertIsNone(json.loads(json.dumps(self.web.monitor_effective(muted)))["sets"]["mains"]["gainDb"])
        shared = self.web.parse_monitor_status(status_text(outs=['out n=3 set=mains role=sub label="Sub"',
                                                                 'out n=3 set=phones role=sub label="Sub"']))
        self.assertEqual(len(shared["outputs"]), 2, "a shared sub repeats with another set")

    def test_hostile_limits_files_are_refused(self):
        good = self.limits_example
        for name, text in {"max_db too low": good.replace("max_db=-6.0", "max_db=-30.1"),
                           "start rule": good.replace("start=reference", "start=loud"),
                           "lock 2": good.replace("lock=1", "lock=2"),
                           "note quote": good.replace('note=""', 'note="a"b"'),
                           "note too long": good.replace('note=""', 'note="' + "x" * 65 + '"'),
                           "repeated ref": good.replace("ref id=nearfield", "ref id=mains"),
                           "no end": good.replace("end\n", ""),
                           "order": good.replace("start=reference\nstart_db=-30.0", "start_db=-30.0\nstart=reference")}.items():
            with self.assertRaises(ValueError, msg=name):
                self.web.parse_monitor_limits(text)
            with self.assertRaises(ValueError, msg=f"applier: {name}"):
                apply_tests.apply_module.parse_monitor_limits(text)

    def test_reading_never_follows_a_link_or_blocks_and_is_bounded(self):
        root = Path(self.tmp.name)
        target = root / "target"
        target.write_text(self.state_example)
        os.symlink(target, root / "link")
        with self.assertRaises(OSError):
            self.web.read_monitor_file(root / "link", 8192)
        os.mkfifo(root / "fifo")
        with self.assertRaises(ValueError):
            self.web.read_monitor_file(root / "fifo", 8192)
        (root / "big").write_text("x" * 8193)
        with self.assertRaises(ValueError):
            self.web.read_monitor_file(root / "big", 8192)
        (root / "utf8").write_bytes(self.state_example.replace("mains", "mäins").encode())
        with self.assertRaises(ValueError):
            self.web.read_monitor_file(root / "utf8", 8192)
        with self.assertRaises(FileNotFoundError):
            self.web.read_monitor_file(root / "absent", 8192)

    def test_limits_absent_present_invalid(self):
        self.assertEqual(self.web.read_monitor_limits(), {**self.web.default_monitor_limits(), "file": "absent"})
        path = self.web.APPLY_STATE / "monitor-limits"
        path.write_text(self.limits_example)
        self.assertEqual(self.web.read_monitor_limits()["file"], "present")
        path.write_text("MONITOR-LIMITS v=1\nmax_db=nan\n")
        self.assertEqual(self.web.read_monitor_limits(), {**self.web.default_monitor_limits(), "file": "invalid"})


class StoreTests(unittest.TestCase):
    """MonitorStore: the run file, the remembered copy, read-back and adoption."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.web = base.load(base.make_spool(root), root / "aes67.conf")
        self.run_dir, self.keep_dir = root / "run", root / "keep"
        self.run_dir.mkdir()
        self.keep_dir.mkdir()
        self.clock = Clock()
        self.status = self.web.parse_monitor_status(status_text())
        self.stderr = mock.patch.object(sys, "stderr", new=io.StringIO())
        self.stderr.start()

    def tearDown(self):
        self.stderr.stop()
        self.tmp.cleanup()

    def store(self):
        return self.web.MonitorStore(self.run_dir, self.keep_dir, clock=self.clock)

    def run_file(self):
        return self.run_dir / "state"

    def keep_file(self):
        return self.keep_dir / "state"

    def test_nothing_is_written_until_a_change(self):
        store = self.store()
        self.assertEqual(store.view(self.status)[1], 0)
        self.assertFalse(self.run_file().exists())
        self.assertFalse(store.tick())
        self.assertFalse(store.flush())
        self.assertEqual(list(self.keep_dir.iterdir()), [])

    def test_a_change_writes_the_run_file_0644_whatever_the_umask(self):
        old = os.umask(0o027)
        try:
            store = self.store()
            state, seq = store.change({"set": "mains", "levelDb": -20.0}, self.status, 0.0)
            self.clock.now += 5
            self.assertTrue(store.tick())
        finally:
            os.umask(old)
        self.assertEqual(seq, 1)
        for path in (self.run_file(), self.keep_file()):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644, path)
        self.assertEqual([p.name for p in self.run_dir.iterdir()], ["state"], "no temporary file left")
        seq, parsed = self.web.parse_monitor_state(self.run_file().read_text())
        self.assertEqual((seq, parsed["sets"]["mains"]["levelDb"]), (1, -20.0))
        self.assertEqual(list(parsed["sets"]), ["mains", "phones"], "every set of the running preset is listed")
        self.assertEqual(parsed["sets"]["phones"]["levelDb"], -30.0, "a new set starts at the owner's values")
        self.assertEqual(state, parsed)

    def test_seq_continues_from_the_run_file_read_back(self):
        store = self.store()
        for level in (-20.0, -21.0, -22.0):
            store.change({"set": "mains", "levelDb": level}, self.status, 0.0)
        again = self.store()
        self.assertTrue(again.run_written)
        state, seq = again.view(self.status)
        self.assertEqual((seq, state["sets"]["mains"]["levelDb"]), (3, -22.0))
        self.assertEqual(again.change({"set": "mains", "mute": True}, self.status, 0.0)[1], 4)

    def test_the_remembered_copy_is_written_2_s_after_the_last_change(self):
        store = self.store()
        store.change({"set": "mains", "levelDb": -20.0, }, self.status, 0.0)
        self.clock.now += 1.5
        store.change({"set": "mains", "levelDb": -19.0}, self.status, 0.0)   # a drag goes on
        self.clock.now += 1.9
        self.assertFalse(store.tick())
        self.assertFalse(self.keep_file().exists())
        store.change({"solo": [True] + [False] * 15}, self.status, 0.0)
        self.clock.now += 2.0
        self.assertTrue(store.tick())
        seq, kept = self.web.parse_monitor_state(self.keep_file().read_text())
        self.assertEqual((seq, kept["sets"]["mains"]["levelDb"]), (3, -19.0))
        self.assertEqual(kept["solo"], [False] * 16, "solo is not remembered")
        self.assertTrue(self.web.parse_monitor_state(self.run_file().read_text())[1]["solo"][0], "it is in the run file")
        self.clock.now += 10
        self.assertFalse(store.tick(), "once per change, not every period")

    def test_flush_on_a_clean_stop_writes_an_unwritten_change(self):
        store = self.store()
        store.change({"dimDb": -12.0}, self.status, 0.0)
        self.assertTrue(store.flush())
        self.assertEqual(self.web.parse_monitor_state(self.keep_file().read_text())[1]["dimDb"], -12.0)
        self.assertFalse(store.flush(), "nothing left to write")

    def test_after_a_boot_the_remembered_copy_is_remembered_and_not_written(self):
        state = self.web.empty_monitor_state()
        state["sets"]["mains"] = {"levelDb": -12.0, "trimDb": 0.0, "dim": False, "mute": False, "fold": "full"}
        state["solo"] = [True] * 16
        self.keep_file().write_text(self.web.render_monitor_state(41, state))
        store = self.store()
        self.assertFalse(self.run_file().exists())
        self.assertFalse(store.run_written)
        view, seq = store.view(self.status)
        self.assertEqual((seq, view["sets"]["mains"]["levelDb"], view["solo"]), (41, -12.0, [False] * 16))
        self.assertFalse(self.run_file().exists(), "a view does not write the run file")
        self.assertEqual(store.change({"subs": False}, self.status, 0.0)[1], 42, "seq continues from the copy")

    def test_the_owners_start_is_adopted_until_the_first_change(self):
        state = self.web.empty_monitor_state()
        state["sets"]["mains"] = {"levelDb": -3.0, "trimDb": 0.0, "dim": False, "mute": False, "fold": "full"}
        state["dimDb"] = -10.0
        self.keep_file().write_text(self.web.render_monitor_state(5, state))
        start = self.web.parse_monitor_status(status_text(state="start", seq="none", active="phones"))
        store = self.store()
        view, _ = store.view(start)
        self.assertEqual((view["sets"]["mains"]["levelDb"], view["active"]), (-30.0, "phones"),
                         "the owner's start rule wins over the remembered -3.0")
        self.assertEqual(view["dimDb"], -10.0, "dim_db is not among what is adopted")
        state, seq = store.change({"set": "phones", "trimDb": 1.0}, start, 0.0)
        self.assertEqual((state["sets"]["mains"]["levelDb"], state["sets"]["phones"]["trimDb"], seq), (-30.0, 1.0, 6))
        later = self.web.parse_monitor_status(status_text(state="start").replace("level_db=-30.0", "level_db=-40.0"))
        self.assertEqual(store.view(later)[0]["sets"]["mains"]["levelDb"], -30.0, "not once the run file is ours")

    def test_a_status_other_than_start_is_not_adopted(self):
        store = self.store()
        applied = self.web.parse_monitor_status(status_text(state="applied"))
        self.assertEqual(store.view(applied)[0]["sets"], {})

    def test_a_bad_run_file_is_discarded_with_a_log_line(self):
        self.run_file().write_text("MONITOR-STATE v=1 seq=9\nactive=all\n")
        state = self.web.empty_monitor_state()
        self.keep_file().write_text(self.web.render_monitor_state(4, state))
        store = self.store()
        self.assertFalse(store.run_written)
        self.assertEqual(store.seq, 4, "the remembered copy instead")
        self.assertIn(f"monitor: {self.run_file()} discarded", sys.stderr.getvalue())

    def test_a_link_at_the_run_path_is_neither_read_nor_written_through(self):
        target = Path(self.tmp.name) / "elsewhere"
        target.write_text(self.web.render_monitor_state(77, self.web.empty_monitor_state()))
        os.symlink(target, self.run_file())
        store = self.store()
        self.assertEqual(store.seq, 0, "the link is not read")
        store.change({"subs": False}, self.status, 0.0)
        self.assertFalse(self.run_file().is_symlink(), "the rename replaced the link itself")
        self.assertIn("seq=77", target.read_text(), "the link's target is untouched")

    def test_an_unwritable_run_directory_changes_nothing(self):
        store = self.store()
        self.run_dir.rmdir()
        with self.assertRaises(OSError):
            store.change({"subs": False}, self.status, 0.0)
        self.assertEqual((store.seq, store.state["subs"], store.dirty), (0, True, False))

    def test_sixteen_sets_at_most_the_remembered_ones_go_first(self):
        state = self.web.empty_monitor_state()
        for i in range(15):
            state["sets"][f"old{i}"] = {"levelDb": -1.0, "trimDb": 0.0, "dim": False, "mute": False, "fold": "full"}
        state["active"] = "old0"
        self.run_file().write_text(self.web.render_monitor_state(1, state))
        store = self.store()
        state, _ = store.change({"set": "mains", "levelDb": -5.0}, self.status, 0.0)
        self.assertEqual(len(state["sets"]), 16)
        self.assertEqual(list(state["sets"])[-2:], ["mains", "phones"])
        self.assertNotIn("old0", state["sets"])
        self.assertEqual(state["active"], "all", "the active set went with it")
        self.web.parse_monitor_state(self.run_file().read_text())


class MonitorServerCase(base.ServerCase):
    def setUp(self):
        super().setUp()
        root = Path(self.tmp.name)
        self.web._stack["name"] = "dante"
        self.status_path = root / "monitor.status"
        self.web.MONITOR_STATUS = self.status_path
        self.run_dir, self.keep_dir = root / "monitor-run", root / "monitor-keep"
        self.run_dir.mkdir()
        self.keep_dir.mkdir()
        self.clock = Clock()
        self.web.Handler.monitor = self.web.MonitorStore(self.run_dir, self.keep_dir, clock=self.clock)
        self.inbox = self.spool / "inbox"
        self.state = self.spool / "state"
        self.set_snapshot()
        self.write_status(status_text())

    def set_snapshot(self, dante="active", apply=True):
        self.web.Handler.collector._snapshot = {
            "ok": True, "services": {"dante": {"unit": "usb16x16-dante.service", "state": dante}},
            "control": {"apply": {"available": apply, "reason": None if apply else "applier is inactive"}},
            "profile": {"selected": "direct", "profiles": []},
        }

    def write_status(self, text):
        temporary = self.status_path.with_name(".status.tmp")
        temporary.write_text(text)
        os.replace(temporary, self.status_path)

    def post(self, body, headers=CHANGE, auth=True, route="/api/monitor"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        status, _, data = self.call("POST", route, headers=headers, body=data, auth=auth)
        return status, json.loads(data) if data else None

    def get(self):
        status, response, data = self.call("GET", "/api/monitor")
        self.assertEqual(status, 200)
        self.assertEqual(response.getheader("Cache-Control"), "no-store")
        return json.loads(data)

    def run_state(self):
        return self.web.parse_monitor_state((self.run_dir / "state").read_text())

    def requests(self):
        return [json.loads(p.read_text()) for p in sorted(self.inbox.glob("*.request"))]


class MonitorRouteTests(MonitorServerCase):
    def test_get_carries_state_effective_topology_and_limits(self):
        answer = self.get()
        self.assertEqual(set(answer), {"ok", "available", "state", "effective", "topology", "limits", "seq"})
        self.assertTrue(answer["available"])
        self.assertEqual(answer["seq"], 0)
        self.assertEqual(answer["effective"]["sets"]["mains"]["kind"], "speakers")
        self.assertEqual(answer["topology"]["sets"][0],
                         {"id": "mains", "kind": "speakers", "folds": ["full", "stereo", "mono"],
                          "outputs": [{"n": 0, "role": "speaker", "label": "Out 1"},
                                      {"n": 1, "role": "speaker", "label": "Out 2"}]})
        self.assertEqual(answer["limits"], {**self.web.default_monitor_limits(), "file": "absent"})

    def test_unavailable_without_a_status_or_the_service_or_on_aes67(self):
        self.status_path.unlink()
        answer = self.get()
        self.assertEqual((answer["ok"], answer["available"]), (True, False))
        self.assertIn("limits", answer)
        self.assertNotIn("state", answer)
        self.write_status("MONITOR v=1 nonsense\n")
        self.assertFalse(self.get()["available"])
        self.write_status(status_text())
        self.set_snapshot(dante="inactive")
        self.assertIn("inactive", self.get()["reason"])
        self.set_snapshot()
        self.web._stack["name"] = "aes67"
        self.assertFalse(self.get()["available"])

    def test_a_status_changed_on_disk_is_read_again(self):
        self.assertEqual(len(self.get()["topology"]["sets"]), 2)
        self.write_status(status_text(sets=(("mains", "speakers", "full"),)))
        self.assertEqual(len(self.get()["topology"]["sets"]), 1)

    def test_a_level_post_writes_the_run_file_at_once(self):
        status, answer = self.post({"set": "mains", "levelDb": -21.37})
        self.assertEqual(status, 200, answer)
        self.assertEqual(set(answer), {"ok", "seq", "state"})
        self.assertEqual((answer["seq"], answer["state"]["sets"]["mains"]["levelDb"]), (1, -21.4))
        seq, state = self.run_state()
        self.assertEqual((seq, state["sets"]["mains"]["levelDb"]), (1, -21.4))
        self.assertEqual(stat.S_IMODE((self.run_dir / "state").stat().st_mode), 0o644)
        self.assertEqual(self.get()["state"], answer["state"])

    def test_every_kind_of_change(self):
        for body in ({"set": "phones", "trimDb": -3.0, "dim": True, "mute": True, "fold": "mono"},
                     {"active": "phones"}, {"active": "all"}, {"dimDb": -40.0}, {"subs": False},
                     {"solo": [True, False] * 8}, {"outMute": [False] * 15 + [True]}):
            status, answer = self.post(body)
            self.assertEqual(status, 200, (body, answer))
        state = self.run_state()[1]
        self.assertEqual(state["sets"]["phones"], {"levelDb": -30.0, "trimDb": -3.0, "dim": True, "mute": True, "fold": "mono"})
        self.assertEqual((state["active"], state["dimDb"], state["subs"]), ("all", -40.0, False))
        self.assertEqual(state["solo"], [True, False] * 8)
        self.assertTrue(state["outMute"][15])
        status, answer = self.post({"clearSolo": True})
        self.assertEqual((status, answer["state"]["solo"], answer["seq"]), (200, [False] * 16, 8))

    def test_the_validation_matrix(self):
        sixteen = [False] * 16
        refused = [
            {}, [], "x", {"bogus": 1}, {"set": "mains"}, {"levelDb": -10.0},
            {"set": "Mains", "levelDb": -1.0}, {"set": 3, "levelDb": -1.0}, {"set": "a" * 33, "levelDb": -1.0},
            {"set": "mains", "levelDb": "-10"}, {"set": "mains", "levelDb": True}, {"set": "mains", "levelDb": None},
            {"set": "mains", "levelDb": 0.5}, {"set": "mains", "levelDb": -60.1}, {"set": "mains", "levelDb": 1e400},
            {"set": "mains", "levelDb": 10 ** 400}, {"set": "mains", "trimDb": 12.5}, {"set": "mains", "dim": 1},
            {"set": "mains", "mute": "true"}, {"set": "mains", "fold": "Full"}, {"set": "mains", "fold": "x" * 17},
            {"active": "Mains"}, {"active": None}, {"dimDb": -41}, {"dimDb": 1}, {"subs": "on"},
            {"solo": sixteen[:15]}, {"solo": sixteen + [False]}, {"solo": [0] * 16}, {"outMute": "0" * 16},
            {"clearSolo": False}, {"clearSolo": True, "solo": sixteen},
        ]
        for body in refused:
            status, answer = self.post(body)
            self.assertEqual(status, 400, (body, answer))
        for text in (b'{"set": "mains", "levelDb": NaN}', b'{"set": "mains", "levelDb": -Infinity}', b"not json"):
            status, _ = self.post(text)
            self.assertEqual(status, 400, text)
        status, _ = self.post({"set": "mains", "levelDb": -1.0, "pad": "x" * 5000})
        self.assertEqual(status, 400, "a body over 4096 bytes")
        self.assertFalse((self.run_dir / "state").exists(), "nothing refused was written")
        for body in ({"set": "mains", "levelDb": -60}, {"set": "mains", "levelDb": 0}, {"dimDb": 0}, {"set": "mains", "trimDb": 12}):
            self.assertEqual(self.post(body)[0], 200, body)

    def test_409_for_what_the_running_preset_does_not_have(self):
        for body in ({"set": "nearfield", "levelDb": -10.0}, {"active": "nearfield"},
                     {"set": "phones", "fold": "stereo"}):
            status, answer = self.post(body)
            self.assertEqual(status, 409, (body, answer))
        self.assertFalse((self.run_dir / "state").exists())

    def test_503_without_a_status(self):
        self.status_path.unlink()
        status, answer = self.post({"set": "mains", "levelDb": -10.0})
        self.assertEqual(status, 503, answer)
        self.set_snapshot(dante="failed")
        self.write_status(status_text())
        self.assertEqual(self.post({"subs": False})[0], 503)
        self.web.Handler.monitor = None
        self.set_snapshot()
        self.assertEqual(self.post({"subs": False})[0], 503, "no store")

    def test_a_level_above_the_maximum_is_lowered_to_it(self):
        (self.state / "monitor-limits").write_text("MONITOR-LIMITS v=1\nmax_db=-12.0\nstart=last\nstart_db=-30.0\nlock=0\nend\n")
        status, answer = self.post({"set": "mains", "levelDb": -3.0})
        self.assertEqual((status, answer["state"]["sets"]["mains"]["levelDb"]), (200, -12.0))
        self.assertEqual(self.run_state()[1]["sets"]["mains"]["levelDb"], -12.0)
        self.assertEqual(self.post({"set": "mains", "levelDb": -20.0})[1]["state"]["sets"]["mains"]["levelDb"], -20.0)

    def test_post_is_gated_like_every_change(self):
        body = {"set": "mains", "levelDb": -10.0}
        self.assertEqual(self.post(body, headers={"Content-Type": "application/json"})[0], 403, "no X-USB-AoIP")
        self.assertEqual(self.post(body, headers={"X-USB-AoIP": "1", "Content-Type": "text/plain"})[0], 403, "not JSON")
        self.assertEqual(self.post(body, headers={**CHANGE, "Origin": "http://evil.example"})[0], 403, "foreign Origin")
        self.assertEqual(self.post(body, auth=False)[0], 401)
        self.assertEqual(self.call("GET", "/api/monitor", auth=False)[0], 401)
        self.assertFalse((self.run_dir / "state").exists())

    def test_a_knob_works_while_an_apply_is_in_flight_or_unavailable(self):
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        (self.state / "current.json").write_text(json.dumps({"state": "verifying", "updatedAt": now}))
        self.web.write_apply_request("direct", None, "tester")
        self.assertTrue(self.web.apply_state()["inFlight"] and self.web.apply_state()["pending"])
        self.assertEqual(self.post({"set": "mains", "levelDb": -10.0})[0], 200)
        self.set_snapshot(apply=False)
        self.assertEqual(self.post({"set": "mains", "levelDb": -11.0})[0], 200)
        self.assertEqual(len(self.requests()), 1, "no request was queued for a knob")

    def test_the_remembered_copy_through_the_routes(self):
        self.post({"set": "mains", "levelDb": -10.0})
        self.clock.now += 2.5
        self.assertTrue(self.web.Handler.monitor.tick())
        self.assertEqual(self.web.parse_monitor_state((self.keep_dir / "state").read_text())[1]["sets"]["mains"]["levelDb"], -10.0)


class MonitorApplyRouteTests(MonitorServerCase):
    def test_limits_are_queued_with_their_fields(self):
        status, answer = self.post({"maxDb": -6.04, "start": "fixed", "startDb": -20, "lock": True},
                                   route="/api/apply/monitor-limits")
        self.assertEqual(status, 202, answer)
        [request] = self.requests()
        self.assertEqual((request["kind"], request["maxDb"], request["start"], request["startDb"], request["lock"]),
                         ("monitor-limits", -6.0, "fixed", -20.0, True))
        self.assertEqual(request["id"], answer["id"])

    def test_limits_validation(self):
        for body in ({}, {"maxDb": -31}, {"maxDb": 1}, {"maxDb": True}, {"start": "loud"}, {"startDb": -61},
                     {"lock": 1}, {"lock": True, "extra": 1}):
            status, answer = self.post(body, route="/api/apply/monitor-limits")
            self.assertEqual(status, 400, (body, answer))
        self.assertEqual(self.requests(), [])

    def test_reference_is_queued(self):
        status, answer = self.post({"set": "mains", "levelDb": -18.0, "note": "79 dB SPL C"},
                                   route="/api/apply/monitor-reference")
        self.assertEqual(status, 202, answer)
        [request] = self.requests()
        self.assertEqual((request["kind"], request["set"], request["levelDb"], request["note"]),
                         ("monitor-reference", "mains", -18.0, "79 dB SPL C"))

    def test_reference_refusals(self):
        for body in ({"set": "mains"}, {"levelDb": -1.0}, {"set": "mains", "levelDb": -1.0, "note": 'a"b'},
                     {"set": "mains", "levelDb": -1.0, "note": "x" * 65}, {"set": "mains", "levelDb": -1.0, "note": "é"},
                     {"set": "mains", "levelDb": -1.0, "x": 1}):
            self.assertEqual(self.post(body, route="/api/apply/monitor-reference")[0], 400, body)
        status, answer = self.post({"set": "nearfield", "levelDb": -1.0}, route="/api/apply/monitor-reference")
        self.assertEqual(status, 409, "not a set of the running preset")
        (self.state / "monitor-limits").write_text("MONITOR-LIMITS v=1\nmax_db=0.0\nstart=last\nstart_db=-30.0\nlock=1\nend\n")
        status, answer = self.post({"set": "mains", "levelDb": -1.0}, route="/api/apply/monitor-reference")
        self.assertEqual(status, 409, answer)
        self.assertIn("locked", answer["error"])
        self.assertEqual(self.requests(), [])
        self.assertEqual(self.post({"lock": False}, route="/api/apply/monitor-limits")[0], 202, "unlocking is allowed")

    def test_the_apply_routes_need_apply_and_the_dante_stack(self):
        self.set_snapshot(apply=False)
        self.assertEqual(self.post({"maxDb": -6.0}, route="/api/apply/monitor-limits")[0], 503)
        self.assertEqual(self.post({"set": "mains", "levelDb": -1.0}, route="/api/apply/monitor-reference")[0], 503)
        self.set_snapshot()
        self.web._stack["name"] = "aes67"
        self.assertEqual(self.post({"maxDb": -6.0}, route="/api/apply/monitor-limits")[0], 409)
        self.assertEqual(self.post({"set": "mains", "levelDb": -1.0}, route="/api/apply/monitor-reference")[0], 409)
        self.assertEqual(self.requests(), [])

    def test_a_reference_while_the_owner_shows_nothing_is_still_queued(self):
        self.status_path.unlink()
        self.assertEqual(self.post({"set": "anything", "levelDb": -1.0}, route="/api/apply/monitor-reference")[0], 202)


class MonitorHealthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = base.make_spool(root)
        self.web = base.load(self.spool, root / "aes67.conf")
        self.web.run = self.systemctl("active")
        self.web.MONITOR_STATUS = root / "monitor.status"

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def systemctl(word):
        """is-active prints one line per unit named."""
        return lambda argv, timeout=4.0: "\n".join([word] * max(1, len(argv) - 2))

    def control(self, stack):
        self.web._stack["name"] = stack
        self.web.detect_stack = lambda: stack
        return self.web.Collector(Path(self.tmp.name), Path(self.tmp.name)).collect_slow()["control"]

    def test_control_monitor(self):
        control = self.control("dante")
        self.assertEqual((control["monitor"]["available"], control["monitor"]["kinds"]),
                         (False, ["monitor-limits", "monitor-reference"]), "the limits do not need the owner")
        self.assertEqual(control["apply"]["actions"][-1], "shutdown", "control.apply.actions is unchanged")
        self.assertNotIn("monitor-limits", control["apply"]["actions"])
        self.web.MONITOR_STATUS.write_text(status_text())
        self.assertTrue(self.control("dante")["monitor"]["available"])
        aes67 = self.control("aes67")["monitor"]
        self.assertEqual((aes67["available"], aes67["kinds"]), (False, []))
        self.web.run = self.systemctl("inactive")
        dead = self.control("dante")["monitor"]
        self.assertEqual((dead["available"], dead["kinds"]), (False, []))


# ------------------------------------------------------------------ the applier

class ApplierMonitorTests(unittest.TestCase):
    apply = apply_tests.apply_module

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = apply_tests.Env(self.tmp.name)
        self.runner = apply_tests.FakeRunner(self.env)
        self.applier = apply_tests.make(self.env, self.runner)
        self.applier.ensure_state()
        self.path = self.env.state / "monitor-limits"
        self.count = 0

    def tearDown(self):
        self.tmp.cleanup()

    def request(self, **fields):
        self.count += 1
        body = {"id": f"{self.count:010x}", "profile": "dsp-direct", "expectedProfile": None,
                "requestedAt": time.time(), "requestedBy": "bryan"}
        body.update(fields)
        self.env.drop(body)
        return body

    def limits(self):
        return self.apply.parse_monitor_limits(self.path.read_text())

    def test_monitor_limits_from_nothing(self):
        self.request(kind="monitor-limits", maxDb=-6.0, lock=True)
        result = self.applier.consume()
        self.assertEqual((result["kind"], result["state"], result["error"]), ("monitor-limits", "done", None))
        self.assertEqual(self.path.read_text(), "MONITOR-LIMITS v=1\nmax_db=-6.0\nstart=last\nstart_db=-30.0\nlock=1\nend\n")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644)
        self.assertEqual(result["limits"], {"maxDb": -6.0, "start": "last", "startDb": -30.0, "lock": True, "refs": {}})
        self.assertEqual([s["name"] for s in result["steps"]], ["validating", "writing"])
        self.assertEqual(self.runner.calls, [], "nothing restarted or signalled")
        self.assertEqual((result["request"]["maxDb"], result["request"]["lock"]), (-6.0, True))
        receipt = json.loads((self.env.state / "receipts" / f"{result['id']}.json").read_text())
        self.assertEqual(receipt["limits"], result["limits"])

    def test_a_reference_and_the_clamp_to_max_db(self):
        self.applier.apply(self.request(kind="monitor-reference", set="mains", levelDb=-8.0, note="79 dB SPL C"))
        self.applier.apply(self.request(kind="monitor-limits", startDb=-20.0, start="fixed"))
        result = self.applier.apply(self.request(kind="monitor-limits", maxDb=-12.0))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertEqual(self.limits(), {"maxDb": -12.0, "start": "fixed", "startDb": -20.0, "lock": False,
                                         "refs": {"mains": {"levelDb": -12.0, "note": "79 dB SPL C"}}})
        self.assertIn('ref id=mains level_db=-12.0 note="79 dB SPL C"\n', self.path.read_text(), "written clamped")
        result = self.applier.apply(self.request(kind="monitor-reference", set="phones", levelDb=-3.0))
        self.assertEqual(result["limits"]["refs"]["phones"], {"levelDb": -12.0, "note": ""})

    def test_a_reference_is_refused_while_locked_and_unlocking_is_allowed(self):
        self.applier.apply(self.request(kind="monitor-limits", lock=True))
        before = self.path.read_bytes()
        result = self.applier.apply(self.request(kind="monitor-reference", set="mains", levelDb=-8.0))
        self.assertEqual(result["state"], "refused")
        self.assertIn("locked", result["error"])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.applier.apply(self.request(kind="monitor-limits", lock=False))["state"], "done")
        self.assertEqual(self.applier.apply(self.request(kind="monitor-reference", set="mains", levelDb=-8.0))["state"], "done")

    def test_a_corrupt_file_is_replaced_by_the_defaults_and_the_request(self):
        self.path.write_text("MONITOR-LIMITS v=1\nmax_db=-6.0\nlock=1\n")
        result = self.applier.apply(self.request(kind="monitor-reference", set="mains", levelDb=-9.0))
        self.assertEqual(result["state"], "done", result["error"])
        self.assertIn("limitsReplaced", result)
        self.assertIn("replaced", result["steps"][0]["detail"])
        self.assertEqual(self.limits(), {**self.apply.default_monitor_limits(),
                                         "refs": {"mains": {"levelDb": -9.0, "note": ""}}})
        self.path.unlink()
        os.symlink(self.env.root / "aes67.conf", self.path)
        result = self.applier.apply(self.request(kind="monitor-limits", maxDb=-1.0))
        self.assertEqual(result["state"], "done")
        self.assertIn("limitsReplaced", result, "a link is not read")
        self.assertFalse(self.path.is_symlink())
        self.assertTrue(self.env.conf.read_text().startswith("PROFILE="), "nor written through")

    def test_refusals(self):
        for fields in ({"kind": "monitor-limits"}, {"kind": "monitor-limits", "maxDb": -31.0},
                       {"kind": "monitor-limits", "maxDb": float("nan")}, {"kind": "monitor-limits", "maxDb": True},
                       {"kind": "monitor-limits", "maxDb": "0"}, {"kind": "monitor-limits", "start": "loud"},
                       {"kind": "monitor-limits", "startDb": 0.1}, {"kind": "monitor-limits", "lock": 1},
                       {"kind": "monitor-reference", "levelDb": -1.0}, {"kind": "monitor-reference", "set": "Mains", "levelDb": -1.0},
                       {"kind": "monitor-reference", "set": "mains"}, {"kind": "monitor-reference", "set": "mains", "levelDb": -61.0},
                       {"kind": "monitor-reference", "set": "mains", "levelDb": -1.0, "note": 'a"b'},
                       {"kind": "monitor-reference", "set": "mains", "levelDb": -1.0, "note": 5}):
            result = self.applier.apply(self.request(**fields))
            self.assertEqual(result["state"], "refused", fields)
        self.assertFalse(self.path.exists())

    def test_seventeen_references_are_refused(self):
        for i in range(16):
            self.assertEqual(self.applier.apply(self.request(kind="monitor-reference", set=f"s{i}", levelDb=-1.0))["state"], "done")
        self.assertEqual(self.applier.apply(self.request(kind="monitor-reference", set="s16", levelDb=-1.0))["state"], "refused")
        self.assertEqual(self.applier.apply(self.request(kind="monitor-reference", set="s3", levelDb=-2.0))["state"], "done",
                         "replacing one of the sixteen is fine")

    def test_a_drain_goes_on_after_them(self):
        self.request(kind="monitor-limits", maxDb=-6.0)
        self.request(kind="monitor-reference", set="mains", levelDb=-3.0)
        self.request(kind="bundle")
        with mock.patch.object(self.apply, "MODINFO", ("modinfo",)):
            self.runner.run = lambda argv, timeout=60.0: (1, "no")
            handled = self.applier.drain()
        self.assertEqual([r["kind"] for r in handled], ["monitor-limits", "monitor-reference", "bundle"])
        self.assertEqual(self.limits()["refs"]["mains"]["levelDb"], -6.0)

    def test_check_says_what_it_would_do(self):
        request = self.request(kind="monitor-limits", maxDb=-6.0)
        self.assertIn("monitor-limits", self.applier.check_system(request))

    def test_the_dante_stack_takes_them_too(self):
        os.mkdir(self.tmp.name + "/dante")
        env = dante_tests.Env(self.tmp.name + "/dante")
        applier = dante_tests.apply_module.DanteApplier(inbox=env.inbox, state_dir=env.state, conf_path=env.conf,
                                                        run_dir=env.run_dir, runner=dante_tests.FakeRunner(env))
        result = applier.apply({"id": "0123456789", "kind": "monitor-limits", "maxDb": -3.0, "requestedAt": time.time()})
        self.assertEqual((result["state"], result["stack"], result["limits"]["maxDb"]), ("done", "dante", -3.0))
        self.assertTrue((env.state / "monitor-limits").read_text().startswith("MONITOR-LIMITS v=1\nmax_db=-3.0\n"))


class ModinfoTests(unittest.TestCase):
    """The support bundle's usb_f_uac2 hash: modinfo by its sbin paths, then
    PATH; when every attempt fails the bundle says why instead of a bare null."""
    apply = apply_tests.apply_module

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = apply_tests.Env(self.tmp.name)
        root = Path(self.tmp.name)
        self.sbin = root / "sbin-modinfo"
        self.sbin.write_text("#!/bin/sh\n")
        self.sbin.chmod(0o755)
        self.module = root / "usb_f_uac2.ko"
        self.module.write_bytes(b"module")
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def bundle_hashes(self, answer):
        env = self.env

        class Runner(apply_tests.FakeRunner):
            def run(inner, argv, timeout=60.0):
                if argv[0] in ("journalctl", "systemctl"):
                    return 0, ""
                self.calls.append(argv[0])
                return answer(argv[0])
        applier = apply_tests.make(env, Runner(env))
        with mock.patch.object(self.apply, "MODINFO", (str(self.tmp.name) + "/absent", str(self.sbin), "modinfo")):
            result = applier.apply(env.request(kind="bundle"))
        self.assertEqual(result["state"], "done", result["error"])
        return json.loads((env.state / "bundles" / result["bundle"]["file"]).read_text())["hashes"]

    def test_the_sbin_path_is_used_when_there(self):
        hashes = self.bundle_hashes(lambda program: (0, str(self.module)) if program == str(self.sbin) else (1, "x"))
        self.assertEqual(hashes[str(self.module)], apply_tests.apply_module.hashlib.sha256(b"module").hexdigest())
        self.assertNotIn("usb_f_uac2_error", hashes)
        self.assertEqual(self.calls, [str(self.sbin)], "an absent path is not run; PATH is not needed")

    def test_path_is_the_last_resort(self):
        hashes = self.bundle_hashes(lambda program: (0, str(self.module) + "\n") if program == "modinfo" else
                                    (1, "modinfo: FATAL: Module usb_f_uac2 not found."))
        self.assertIn(str(self.module), hashes)
        self.assertEqual(self.calls, [str(self.sbin), "modinfo"])

    def test_every_failure_is_recorded(self):
        hashes = self.bundle_hashes(lambda program: (1, "modinfo: FATAL: Module usb_f_uac2 not found in directory /lib/modules/6.18.34"))
        self.assertIsNone(hashes["usb_f_uac2"])
        why = hashes["usb_f_uac2_error"]
        self.assertIn("absent: not there", why)
        self.assertIn(f"{self.sbin} exited 1: modinfo: FATAL: Module usb_f_uac2 not found", why)
        self.assertIn("modinfo exited 1", why)

    def test_a_module_that_cannot_be_read_says_so(self):
        hashes = self.bundle_hashes(lambda program: (0, "/lib/modules/hidden/usb_f_uac2.ko"))
        self.assertIsNone(hashes["/lib/modules/hidden/usb_f_uac2.ko"])
        self.assertEqual(hashes["usb_f_uac2_error"], "/lib/modules/hidden/usb_f_uac2.ko could not be read")


if __name__ == "__main__":
    unittest.main()
