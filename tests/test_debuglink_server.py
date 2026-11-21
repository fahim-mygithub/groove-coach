import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "debuglink"))
import server  # noqa: E402


class DebugLinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.tuning = root / "tuning.json"
        self.tuning.write_text('{"a": 1}')
        self.srv = server.make_server("127.0.0.1", 0, root / "data", self.tuning, ["x"])
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.tmp.cleanup()

    def req(self, path, data=None, headers=None):
        r = urllib.request.Request(self.base + path, data=data, headers=headers or {},
                                   method="POST" if data is not None else "GET")
        try:
            return urllib.request.urlopen(r)
        except urllib.error.HTTPError as e:
            return e

    def test_telemetry(self):
        self.assertEqual(self.req("/telemetry", b'{"step":1,"cue":"c"}').status, 204)
        self.assertEqual(self.req("/telemetry", b'[{"step":2},{"step":3,"x":9}]').status, 204)
        files = list(self.srv.state.data.glob("telemetry-*.jsonl"))
        self.assertEqual(len(files), 1)
        lines = [json.loads(l) for l in files[0].read_text().splitlines()]
        self.assertEqual([l["step"] for l in lines], [1, 2, 3])
        self.assertTrue(all("recv_ts" in l for l in lines))

    def test_frame(self):
        self.assertEqual(self.req("/frame", b"\xff\xd8jpeg", {"X-Frame-Label": "t"}).status, 204)
        fr = self.srv.state.data / "frames"
        self.assertEqual((fr / "latest.jpg").read_bytes(), b"\xff\xd8jpeg")
        self.assertEqual(len(list(fr.glob("frame-*.jpg"))), 1)

    def test_tuning_etag_and_edit(self):
        r = self.req("/tuning.json")
        etag = r.headers["ETag"]
        self.assertEqual(json.loads(r.read()), {"a": 1})
        self.assertEqual(self.req("/tuning.json", headers={"If-None-Match": etag}).status, 304)
        self.tuning.write_text('{"a": 2}')
        r2 = self.req("/tuning.json", headers={"If-None-Match": etag})
        self.assertEqual(r2.status, 200)
        self.assertNotEqual(r2.headers["ETag"], etag)

    def test_invalid_json_keeps_last_valid(self):
        self.req("/tuning.json").read()
        self.tuning.write_text("{broken")
        r = self.req("/tuning.json")
        self.assertEqual(r.status, 200)
        self.assertEqual(json.loads(r.read()), {"a": 1})

    def test_oversize(self):
        self.assertEqual(self.req("/telemetry", b"x" * (8 * 1024 * 1024 + 1)).code, 413)

    def test_body_limit_is_8mb(self):
        self.assertEqual(server.MAX_BODY, 8 * 1024 * 1024)
        big = b"\xff\xd8" + b"x" * (6 * 1024 * 1024)
        self.assertEqual(self.req("/screen", big, {"X-Screen-Name": "big"}).status, 204)
        self.assertEqual((self.srv.state.data / "screen" / "latest.jpg").read_bytes(), big)

    def test_health_and_status(self):
        r = self.req("/health")
        self.assertEqual(r.headers[server.HEALTH_HEADER], server.PROTOCOL_VERSION)
        self.assertEqual(r.read(), b"ok")
        page = self.req("/")
        self.assertEqual(page.status, 200)
        self.assertIn(b"/screen/latest.jpg", page.read())

    def test_log_batch(self):
        body = json.dumps({"device": "iPhone16,1", "lines": [
            {"ts": 1.0, "level": "info", "msg": "hello", "file": "A.swift", "line": 3},
            {"ts": 2.0, "level": "error", "msg": "boom"}]}).encode()
        self.assertEqual(self.req("/log", body).status, 204)
        self.assertEqual(self.req("/log", b'[{"level":"stdout","msg":"x"}]').status, 204)
        self.assertEqual(self.req("/log", b'{"lines": 3}').code, 400)
        self.assertEqual(self.req("/log", b'{nope').code, 400)
        files = list(self.srv.state.data.glob("logs-*.jsonl"))
        self.assertEqual(len(files), 1)
        lines = [json.loads(l) for l in files[0].read_text().splitlines()]
        self.assertEqual([l["msg"] for l in lines], ["hello", "boom", "x"])
        self.assertEqual(lines[0]["device"], "iPhone16,1")
        tail = json.loads(self.req("/tail.json?n=2").read())
        self.assertEqual([l["msg"] for l in tail["logs"]], ["boom", "x"])
        status = json.loads((self.srv.state.data / "status.json").read_text())
        self.assertEqual(status["device"], "iPhone16,1")
        self.assertEqual(status["last_error"]["msg"], "boom")
        self.assertTrue(status["connected"])

    def test_events(self):
        self.assertEqual(self.req("/event", b'[{"kind":"screen_appear","screen":"Courses","deviceModel":"d"},'
                                            b'{"kind":"crash","reason":"SIGSEGV"}]').status, 204)
        self.assertEqual(self.req("/event", b'{"kind":"take_end"}').status, 204)
        self.assertEqual(self.req("/event", b'[1]').code, 400)
        files = list(self.srv.state.data.glob("events-*.jsonl"))
        self.assertEqual(len(files), 1)
        kinds = [json.loads(l)["kind"] for l in files[0].read_text().splitlines()]
        self.assertEqual(kinds, ["screen_appear", "crash", "take_end"])
        status = json.loads(self.req("/status.json").read())
        self.assertIn("SIGSEGV", status["last_error"]["msg"])

    def test_screen_latest_and_rotation(self):
        self.assertEqual(self.req("/screen/latest.jpg").code, 404)
        old_keep = server.KEEP_SCREENS
        server.KEEP_SCREENS = 3
        try:
            for i in range(5):
                self.assertEqual(self.req("/screen", b"\xff\xd8%d" % i, {"X-Screen-Name": "s%d" % i}).status, 204)
        finally:
            server.KEEP_SCREENS = old_keep
        sd = self.srv.state.data / "screen"
        kept = sorted(sd.glob("screen-*.jpg"))
        self.assertEqual([p.read_bytes() for p in kept], [b"\xff\xd82", b"\xff\xd83", b"\xff\xd84"])
        self.assertEqual((sd / "latest.jpg").read_bytes(), b"\xff\xd84")
        self.assertEqual(self.req("/screen/latest.jpg").read(), b"\xff\xd84")
        self.assertEqual(self.req("/screen", b"").code, 400)
        status = json.loads((self.srv.state.data / "status.json").read_text())
        self.assertEqual(status["latest_screen"], "s4")
        self.assertEqual(status["counts"]["screen"], 5)
        self.assertGreater(status["fps"], 0)

    def test_default_keeps_300_screens(self):
        self.assertEqual(server.KEEP_SCREENS, 300)

    def test_unknown_post_404(self):
        self.assertEqual(self.req("/nope", b"{}").code, 404)


class BonjourOptionalTests(unittest.TestCase):
    def test_starts_without_zeroconf(self):
        # Simulate zeroconf being absent even if it is installed here.
        saved = sys.modules.get("zeroconf")
        sys.modules["zeroconf"] = None  # makes `import zeroconf` raise ImportError
        try:
            with tempfile.TemporaryDirectory() as tmp:
                srv = server.make_server("127.0.0.1", 0, Path(tmp) / "d")
                try:
                    self.assertIsNone(server.start_bonjour(srv.server_address[1], ["127.0.0.1"], srv.state))
                    self.assertTrue(srv.state.bonjour.startswith("unavailable"))
                    threading.Thread(target=srv.serve_forever, daemon=True).start()
                    url = "http://127.0.0.1:%d/health" % srv.server_address[1]
                    self.assertEqual(urllib.request.urlopen(url).read(), b"ok")
                finally:
                    srv.shutdown()
                    srv.server_close()
        finally:
            if saved is None:
                del sys.modules["zeroconf"]
            else:
                sys.modules["zeroconf"] = saved

    def test_module_imports_with_stdlib_only(self):
        src = (Path(server.__file__)).read_text(encoding="utf-8")
        self.assertNotIn("\nimport zeroconf", src)
        self.assertNotIn("\nfrom zeroconf", src)

if __name__ == "__main__":
    unittest.main()
