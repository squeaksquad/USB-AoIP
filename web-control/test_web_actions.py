"""Unit tests for usb16x16-web 1.8.0's System actions: the POST routes
reboot, restart-audio, restart-clock, bundle and password under /api/apply/,
the support bundle download GET /api/support/<id>, control.apply.actions in
the health snapshot, receipts through /api/apply/status, and the
Authenticator dropping its cache when the login file changes.
Run from the repo root: python3 -m unittest web-control/test_web_actions.py"""
import base64
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_web as base   # noqa: E402  (a module, so its TestCases are not collected twice)

CHANGE = base.CHANGE
PASSWORD = "new password 1"


class ActionCase(base.ServerCase):
    STACK = "dante"

    def setUp(self):
        super().setUp()
        self.web._stack["name"] = self.STACK
        self.inbox = self.spool / "inbox"
        self.state = self.spool / "state"
        self.set_apply(True)

    def set_apply(self, available, selected="direct"):
        self.web.Handler.collector._snapshot = {
            "ok": True,
            "control": {"apply": {"available": available, "reason": None if available else "applier is inactive"}},
            "profile": {"selected": selected, "profiles": []},
        }

    def post(self, route, body, headers=CHANGE, auth=True):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        return self.call("POST", f"/api/apply/{route}", headers=headers, body=data, auth=auth)

    def requests(self):
        return [json.loads(p.read_text()) for p in sorted(self.inbox.glob("*.request"))]

    def assert_queued(self, status, data, kind):
        self.assertEqual(status, 202, data)
        answer = json.loads(data)
        self.assertEqual(set(answer), {"ok", "id", "kind", "note"})
        self.assertTrue(answer["ok"])
        self.assertEqual(answer["kind"], kind)
        [request] = self.requests()
        self.assertEqual(request["id"], answer["id"])
        self.assertEqual(request["kind"], kind)
        self.assertEqual(request["requestedBy"], self.USER)
        self.assertIsNone(request["expectedProfile"])
        self.assertEqual(request["profile"], "direct")
        return answer, request


class DanteActionTests(ActionCase):
    def test_confirmed_kinds_are_queued_with_no_extra_fields(self):
        for kind in ("reboot", "restart-audio", "restart-clock"):
            for path in self.inbox.iterdir():
                path.unlink()
            self.web._last_request["id"] = None
            status, _, data = self.post(kind, {"confirm": kind})
            answer, request = self.assert_queued(status, data, kind)
            self.assertEqual(set(request), {"id", "profile", "expectedProfile", "requestedAt", "requestedBy", "kind"})
            self.assertNotIn("about a minute", answer["note"])
        self.assertIn("restarts with it", answer["note"], "the endpoint restarts with the clock")

    def test_restart_notes_use_the_stacks_outage_words(self):
        status, _, data = self.post("restart-audio", {"confirm": "restart-audio"})
        self.assertEqual(status, 202, data)
        self.assertIn(self.web.words()["outage"], json.loads(data)["note"])

    def test_confirm_must_name_the_action(self):
        for kind in ("reboot", "restart-audio", "restart-clock"):
            for body in ({}, {"confirm": "shutdown"}, {"confirm": kind.upper()}, [kind], b"not json"):
                status, _, data = self.post(kind, body)
                self.assertEqual(status, 400, (kind, body, data))
        status, _, data = self.call("POST", "/api/apply/reboot", headers={"X-USB-AoIP": "1"})
        self.assertEqual(status, 400, "no body at all")
        self.assertEqual(self.requests(), [])

    def test_bundle_is_queued(self):
        status, _, data = self.post("bundle", {})
        answer, request = self.assert_queued(status, data, "bundle")
        self.assertIn("one file with the logs, versions, start check result and the running preset", answer["note"])

    def test_bundle_needs_a_json_object(self):
        status, _, _ = self.call("POST", "/api/apply/bundle", headers={"X-USB-AoIP": "1"})
        self.assertEqual(status, 400)
        status, _, _ = self.post("bundle", [])
        self.assertEqual(status, 400)
        self.assertEqual(self.requests(), [])

    def test_every_new_route_is_gated(self):
        for route, body in (("reboot", {"confirm": "reboot"}), ("restart-audio", {"confirm": "restart-audio"}),
                            ("restart-clock", {"confirm": "restart-clock"}), ("bundle", {}),
                            ("password", {"password": PASSWORD})):
            status, _, _ = self.post(route, body, headers={"Content-Type": "application/json"})
            self.assertEqual(status, 403, f"{route}: no X-USB-AoIP header")
            status, _, _ = self.post(route, body, headers={"X-USB-AoIP": "1", "Content-Type": "text/plain"})
            self.assertEqual(status, 403, f"{route}: not JSON")
            status, _, _ = self.post(route, body, headers={**CHANGE, "Origin": "http://evil.example"})
            self.assertEqual(status, 403, f"{route}: foreign Origin")
            status, _, _ = self.post(route, body, auth=False)
            self.assertEqual(status, 401, f"{route}: not signed in")
        self.assertEqual(self.requests(), [])

    def test_every_new_route_needs_apply(self):
        self.set_apply(False)
        for route, body in (("reboot", {"confirm": "reboot"}), ("restart-audio", {"confirm": "restart-audio"}),
                            ("restart-clock", {"confirm": "restart-clock"}), ("bundle", {}),
                            ("password", {"password": PASSWORD})):
            status, _, data = self.post(route, body)
            self.assertEqual(status, 503, route)
            self.assertIn("applier is inactive", json.loads(data)["error"])
        self.assertEqual(self.requests(), [])

    def test_one_operation_at_a_time(self):
        status, _, _ = self.post("bundle", {})
        self.assertEqual(status, 202)
        status, _, data = self.post("restart-audio", {"confirm": "restart-audio"})
        self.assertEqual(status, 409, data)
        self.assertEqual(len(self.requests()), 1)

    def test_password_queues_a_hash_that_verifies_and_never_the_password(self):
        del self.web.Handler.log_message   # the real request log, to stderr
        status, response, data = self.post("password", {"password": PASSWORD})
        answer, request = self.assert_queued(status, data, "password")
        self.assertEqual(request["user"], self.USER)
        self.assertTrue(self.web.PasswordFile.verify_password(PASSWORD, request["hash"]))
        self.assertFalse(self.web.PasswordFile.verify_password(self.PASSWORD, request["hash"]))
        self.assertRegex(request["hash"], r"^pbkdf2_sha256\$[0-9]{6,8}\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$")
        self.assertGreaterEqual(int(request["hash"].split("$")[1]), 210000)
        for path in self.inbox.iterdir():
            self.assertNotIn(PASSWORD.encode(), path.read_bytes(), path.name)
        for text in (data.decode(), str(response.getheaders()), sys.stderr.getvalue()):
            self.assertNotIn(PASSWORD, text)
            self.assertNotIn(request["hash"], text)
            self.assertNotIn(request["hash"].split("$")[3], text)
        self.assertIn("/api/apply/password", sys.stderr.getvalue(), "the request was logged, without its body")

    def test_password_refusals(self):
        for body, why in (({"password": "short"}, "Use at least 8 characters."),
                          ({"password": "1234567"}, "Use at least 8 characters."),
                          ({"password": "x" * 257}, "at most 256"),
                          ({"password": 12345678}, "must be a string"),
                          ({}, "must be a string")):
            status, _, data = self.post("password", body)
            self.assertEqual(status, 400, body)
            self.assertIn(why, json.loads(data)["error"])
            if isinstance(body.get("password"), str):
                self.assertNotIn(body["password"], data.decode(), "never echoed")
        status, _, _ = self.post("password", {"password": "x" * 256})
        self.assertEqual(status, 202, "256 characters is the limit, not past it")

    def test_password_body_is_small(self):
        status, _, _ = self.post("password", {"password": PASSWORD, "pad": "x" * 5000})
        self.assertEqual(status, 400)
        self.assertEqual(self.requests(), [])

    def test_status_passes_the_receipt_fields_through(self):
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        receipt = {"id": "0123456789abcdef", "kind": "bundle", "state": "done", "updatedAt": now, "steps": [],
                   "bundle": {"file": "0123456789abcdef.json", "bytes": 1234}, "error": None}
        (self.state / "current.json").write_text(json.dumps(receipt))
        status, _, data = self.call("GET", "/api/apply/status")
        self.assertEqual(status, 200)
        current = json.loads(data)["current"]
        self.assertEqual((current["kind"], current["bundle"], current["state"]),
                         ("bundle", {"file": "0123456789abcdef.json", "bytes": 1234}, "done"))
        receipt.update({"kind": "password", "user": "tester"})
        del receipt["bundle"]
        (self.state / "current.json").write_text(json.dumps(receipt))
        current = json.loads(self.call("GET", "/api/apply/status")[2])["current"]
        self.assertEqual((current["kind"], current["user"]), ("password", "tester"))


class SupportDownloadTests(ActionCase):
    IDENT = "0123456789abcdef"

    def bundles(self):
        directory = self.state / "bundles"
        directory.mkdir(exist_ok=True)
        return directory

    def test_a_bundle_is_served_as_a_download(self):
        content = json.dumps({"format": "usb-aoip-support/1"}, indent=1).encode()
        (self.bundles() / f"{self.IDENT}.json").write_bytes(content)
        status, response, data = self.call("GET", f"/api/support/{self.IDENT}")
        self.assertEqual(status, 200)
        self.assertEqual(data, content)
        self.assertEqual(response.getheader("Content-Type"), "application/json")
        self.assertEqual(response.getheader("Content-Disposition"), 'attachment; filename="usb-aoip-support.json"')
        self.assertEqual(response.getheader("Cache-Control"), "no-store")
        self.assertEqual(response.getheader("X-Content-Type-Options"), "nosniff")
        status, response, data = self.call("HEAD", f"/api/support/{self.IDENT}")
        self.assertEqual((status, data), (200, b""))

    def test_missing_is_404(self):
        status, _, _ = self.call("GET", f"/api/support/{self.IDENT}")
        self.assertEqual(status, 404, "no bundles directory")
        self.bundles()
        status, _, _ = self.call("GET", f"/api/support/{self.IDENT}")
        self.assertEqual(status, 404)

    def test_a_bad_id_is_404_and_reaches_no_file(self):
        (self.state / "current.json").write_text("{}")
        (self.bundles() / f"{self.IDENT}.json").write_text("{}")
        for ident in ("..%2fcurrent", "../current", "%2e%2e%2fcurrent", "0123456789ABCDEF", "abc", "a" * 33,
                      f"{self.IDENT}.json", f"{self.IDENT}%0a", f"{self.IDENT}%00", "", f"{self.IDENT}/x"):
            status, _, data = self.call("GET", f"/api/support/{ident}")
            self.assertEqual(status, 404, ident)
            self.assertNotEqual(data, b"{}", ident)

    def test_a_link_is_not_followed(self):
        target = Path(self.tmp.name) / "elsewhere.json"
        target.write_text('{"secret": 1}')
        os.symlink(target, self.bundles() / f"{self.IDENT}.json")
        status, _, data = self.call("GET", f"/api/support/{self.IDENT}")
        self.assertEqual(status, 404)
        self.assertNotIn(b"secret", data)

    def test_not_a_regular_file_and_too_large(self):
        (self.bundles() / f"{self.IDENT}.json").mkdir()
        self.assertEqual(self.call("GET", f"/api/support/{self.IDENT}")[0], 404, "a directory")
        fifo = self.bundles() / "00000000aaaaaaaa.json"
        os.mkfifo(fifo)
        self.assertEqual(self.call("GET", "/api/support/00000000aaaaaaaa")[0], 404, "a FIFO, without blocking")
        big = self.bundles() / "11111111bbbbbbbb.json"
        with open(big, "wb") as handle:
            handle.truncate(self.web.SUPPORT_BUNDLE_MAX + 1)
        self.assertIsNone(self.web.read_support_bundle("11111111bbbbbbbb"))
        with open(big, "wb") as handle:
            handle.truncate(self.web.SUPPORT_BUNDLE_MAX)
        self.assertEqual(len(self.web.read_support_bundle("11111111bbbbbbbb")), self.web.SUPPORT_BUNDLE_MAX)


class Aes67ActionTests(ActionCase):
    STACK = "aes67"

    def test_restart_clock_is_refused_on_this_stack(self):
        status, _, data = self.post("restart-clock", {"confirm": "restart-clock"})
        self.assertEqual(status, 409, data)
        self.assertIn("no separate clock service", json.loads(data)["error"])
        self.assertEqual(self.requests(), [])

    def test_the_other_actions_are_queued(self):
        for route, body in (("restart-audio", {"confirm": "restart-audio"}), ("reboot", {"confirm": "reboot"}),
                            ("bundle", {}), ("password", {"password": PASSWORD})):
            for path in self.inbox.iterdir():
                path.unlink()
            status, _, data = self.post(route, body)
            self.assert_queued(status, data, route)


class NoAuthTests(ActionCase):
    def setUp(self):
        super().setUp()
        self.web.Handler.auth = None

    def test_password_is_refused_without_sign_in(self):
        status, _, data = self.post("password", {"password": PASSWORD})
        self.assertEqual(status, 409, data)
        self.assertIn("--no-auth", json.loads(data)["error"])
        status, _, data = self.post("password", {"password": PASSWORD}, auth=False)
        self.assertEqual(status, 409, data)
        self.assertEqual(self.requests(), [])

    def test_the_other_actions_still_work(self):
        status, _, data = self.post("bundle", {}, auth=False)
        self.assertEqual(status, 202, data)


class HealthActionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.spool = base.make_spool(root)
        conf = root / "aes67.conf"
        conf.write_text("PROFILE=dsp-direct\nPROFILE_DSP_DIRECT_STATUS=accepted\nPROFILE_DSP_DIRECT_TARGET=48\n")
        self.web = base.load(self.spool, conf)
        self.web.run = lambda argv, timeout=4.0: "active"

    def tearDown(self):
        self.tmp.cleanup()

    def actions(self, stack, auth=True):
        self.web._stack["name"] = stack
        self.web.detect_stack = lambda: stack
        collector = self.web.Collector(Path(self.tmp.name), Path(self.tmp.name), auth=auth)
        return collector.collect_slow()["control"]["apply"]

    def test_the_rule(self):
        everything = ["restart-audio", "restart-clock", "bundle", "password", "reboot", "shutdown"]
        self.assertEqual(self.web.apply_actions(True, True, True), everything)
        self.assertEqual(self.web.apply_actions(True, False, True), [a for a in everything if a != "restart-clock"])
        self.assertEqual(self.web.apply_actions(True, True, False), [a for a in everything if a != "password"])
        self.assertEqual(self.web.apply_actions(True, False, False),
                         ["restart-audio", "bundle", "reboot", "shutdown"])
        for dante in (True, False):
            for auth in (True, False):
                self.assertEqual(self.web.apply_actions(False, dante, auth), [])
                self.assertIn("shutdown", self.web.apply_actions(True, dante, auth))

    def test_health_carries_the_list_per_stack_and_auth(self):
        apply = self.actions("dante")
        self.assertTrue(apply["available"], apply)
        self.assertEqual(apply["actions"], ["restart-audio", "restart-clock", "bundle", "password", "reboot", "shutdown"])
        self.assertEqual(self.actions("dante", auth=False)["actions"],
                         ["restart-audio", "restart-clock", "bundle", "reboot", "shutdown"])
        self.assertEqual(self.actions("aes67")["actions"],
                         ["restart-audio", "bundle", "password", "reboot", "shutdown"])
        self.assertEqual(self.actions("aes67", auth=False)["actions"], ["restart-audio", "bundle", "reboot", "shutdown"])

    def test_empty_when_apply_is_unavailable(self):
        self.web.run = lambda argv, timeout=4.0: "inactive"
        apply = self.actions("dante")
        self.assertFalse(apply["available"])
        self.assertEqual(apply["actions"], [])
        self.web.run = lambda argv, timeout=4.0: "active"
        os.rmdir(self.spool / "inbox")
        apply = self.actions("aes67")
        self.assertFalse(apply["available"])
        self.assertEqual(apply["actions"], [])


class AuthCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.web = base.load(base.make_spool(root), root / "aes67.conf")
        self.path = root / "web-auth"
        self.file = self.web.PasswordFile(self.path)
        self.file.write({"tester": self.web.PasswordFile.hash_password("password A", iterations=1000)})
        self.auth = self.web.Authenticator(self.file)

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def header(password):
        return "Basic " + base64.b64encode(f"tester:{password}".encode()).decode()

    def test_a_changed_file_drops_the_cache_on_the_next_request(self):
        a = self.header("password A")
        self.assertFalse(self.auth.cached(a))
        self.assertTrue(self.auth.verify(a))
        self.assertTrue(self.auth.cached(a), "a verified credential is cached")
        # The applier replaces the file (a new inode, as its rename does).
        self.file.write({"tester": self.web.PasswordFile.hash_password("password B", iterations=1000)})
        self.assertFalse(self.auth.cached(a), "the old password's cache entry is gone at once")
        self.assertFalse(self.auth.verify(a), "and the old password no longer verifies")
        b = self.header("password B")
        self.assertTrue(self.auth.verify(b))
        self.assertTrue(self.auth.cached(b))

    def test_an_in_place_rewrite_is_a_change_too(self):
        a = self.header("password A")
        self.assertTrue(self.auth.verify(a))
        self.assertTrue(self.auth.cached(a))
        info = self.path.stat()
        self.path.write_text(self.path.read_text())   # same inode, same size
        os.utime(self.path, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000))
        self.assertFalse(self.auth.cached(a))

    def test_a_missing_file_is_a_change(self):
        a = self.header("password A")
        self.assertTrue(self.auth.verify(a))
        self.path.unlink()
        self.assertFalse(self.auth.cached(a))
        self.assertFalse(self.auth.verify(a))

    def test_an_unchanged_file_keeps_the_cache_and_costs_no_kdf(self):
        a = self.header("password A")
        self.assertTrue(self.auth.verify(a))
        with mock.patch.object(self.web.hashlib, "pbkdf2_hmac", side_effect=AssertionError("KDF")):
            for _ in range(5):
                self.assertTrue(self.auth.cached(a))

    def test_a_wrong_password_is_still_never_cached(self):
        wrong = self.header("not it")
        self.assertFalse(self.auth.verify(wrong))
        self.assertFalse(self.auth.cached(wrong))

    def test_a_success_against_a_file_that_changed_meanwhile_is_not_cached(self):
        a = self.header("password A")
        real = self.file.load
        def load_then_change():
            users = real()
            self.file.write({"tester": self.web.PasswordFile.hash_password("password B", iterations=1000)})
            return users
        self.file.load = load_then_change
        self.assertTrue(self.auth.verify(a), "it matched the file as read")
        self.file.load = real
        self.assertFalse(self.auth.cached(a))


class AuthCacheServerTests(ActionCase):
    def test_the_old_password_is_refused_on_the_next_request(self):
        status, _, _ = self.call("GET", "/api/health")
        self.assertEqual(status, 200)
        status, _, _ = self.call("GET", "/api/health")
        self.assertEqual(status, 200, "from the cache")
        auth_file = self.web.Handler.auth.password_file
        auth_file.write({self.USER: self.web.PasswordFile.hash_password("another one", iterations=1000)})
        status, _, _ = self.call("GET", "/api/health")
        self.assertEqual(status, 401)
        status, _, _ = self.call("GET", "/api/health", headers=self.basic("another one"), auth=False)
        self.assertEqual(status, 200)


if __name__ == "__main__":
    unittest.main()
