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
        self.assertEqual(self.req("/telemetry", b"x" * (2 * 1024 * 1024 + 1)).code, 413)

    def test_health_and_status(self):
        self.assertEqual(self.req("/health").read(), b"ok")
        self.assertEqual(self.req("/").status, 200)


if __name__ == "__main__":
    unittest.main()
