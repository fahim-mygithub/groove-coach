#!/usr/bin/env python3
"""Groove Coach debug link server (LAN debug only, no auth). Stdlib only.

python tools/debuglink/server.py --port 8765 --data <dir> [--tuning <path>] [--watch k1,k2]
"""
import argparse
import hashlib
import json
import os
import socket
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 2 * 1024 * 1024
KEEP_FRAMES = 200
DEFAULT_TUNING = Path(__file__).resolve().parent / "tuning.json"


def default_data_dir():
    base = os.environ.get("LOCALAPPDATA")
    if os.name == "nt" and base:
        return Path(base) / "groove-coach" / "debuglink"
    return Path.home() / ".groove-coach" / "debuglink"


def lan_addresses():
    addrs = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        addrs.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(a for a in addrs if not a.startswith("127."))


class State:
    def __init__(self, data_dir, tuning_path, watch):
        self.data = Path(data_dir)
        self.frames = self.data / "frames"
        self.frames.mkdir(parents=True, exist_ok=True)
        self.tuning_path = Path(tuning_path)
        self.watch = [k for k in watch if k]
        self.lock = threading.Lock()
        self.last_telemetry = None
        self.last_frame_time = None
        self.last_good = None  # (bytes, etag)
        self.frame_seq = 0

    def tuning(self):
        with self.lock:
            try:
                raw = self.tuning_path.read_bytes()
                json.loads(raw.decode("utf-8"))
                self.last_good = (raw, hashlib.sha256(raw).hexdigest())
            except (OSError, ValueError) as e:
                print("WARN: tuning file unreadable/invalid (%s); serving last valid copy" % e,
                      file=sys.stderr, flush=True)
            return self.last_good

    def add_telemetry(self, items):
        now = time.time()
        day = datetime.fromtimestamp(now).strftime("%Y%m%d")
        with self.lock:
            with open(self.data / ("telemetry-%s.jsonl" % day), "a", encoding="utf-8") as f:
                for it in items:
                    it["recv_ts"] = now
                    f.write(json.dumps(it, separators=(",", ":")) + "\n")
                    self.last_telemetry = it
                    keys = ["step", "cue"] + self.watch
                    print(" ".join("%s=%s" % (k, it[k]) for k in keys if k in it) or "(telemetry)",
                          flush=True)

    def add_frame(self, body, label):
        with self.lock:
            self.frame_seq += 1
            now = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            (self.frames / "latest.jpg").write_bytes(body)
            (self.frames / ("frame-%s-%d.jpg" % (now, self.frame_seq))).write_bytes(body)
            old = sorted(self.frames.glob("frame-*.jpg"))
            for p in old[:-KEEP_FRAMES]:
                try:
                    p.unlink()
                except OSError:
                    pass
            self.last_frame_time = time.time()
        print("frame saved%s" % (" [%s]" % label if label else ""), flush=True)


class Handler(BaseHTTPRequestHandler):
    state = None  # set on subclass
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _reply(self, code, body=b"", ctype=None, headers=None):
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        empty = code in (204, 304)
        self.send_header("Content-Length", "0" if empty else str(len(body)))
        self.end_headers()
        if body and not empty:
            self.wfile.write(body)

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            self._reply(400, b"bad length", "text/plain", {"Connection": "close"})
            return None
        if n > MAX_BODY:
            # Drain (bounded) so the client can read the 413 instead of a reset.
            left = min(n, 64 * MAX_BODY)
            while left > 0:
                chunk = self.rfile.read(min(65536, left))
                if not chunk:
                    break
                left -= len(chunk)
            self.close_connection = True
            self._reply(413, b"too large", "text/plain", {"Connection": "close"})
            return None
        return self.rfile.read(n)

    def do_POST(self):
        path = self.path.split("?")[0]
        if path not in ("/telemetry", "/frame"):
            self.close_connection = True
            self._reply(404, b"not found", "text/plain", {"Connection": "close"})
            return
        body = self._read_body()
        if body is None:
            return
        if path == "/telemetry":
            try:
                obj = json.loads(body.decode("utf-8"))
            except ValueError:
                self._reply(400, b"invalid json", "text/plain")
                return
            items = obj if isinstance(obj, list) else [obj]
            if not all(isinstance(i, dict) for i in items):
                self._reply(400, b"expected object(s)", "text/plain")
                return
            self.state.add_telemetry(items)
        else:
            self.state.add_frame(body, self.headers.get("X-Frame-Label"))
        self._reply(204)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._reply(200, b"ok", "text/plain")
        elif path == "/tuning.json":
            raw, etag = self.state.tuning() or (b"{}", hashlib.sha256(b"{}").hexdigest())
            tag = '"%s"' % etag
            if self.headers.get("If-None-Match", "").strip() == tag:
                self._reply(304, headers={"ETag": tag})
            else:
                self._reply(200, raw, "application/json", {"ETag": tag})
        elif path == "/":
            st = self.state
            good = st.tuning()
            with st.lock:
                lt = json.dumps(st.last_telemetry) if st.last_telemetry else "none"
                lf = (datetime.fromtimestamp(st.last_frame_time).isoformat()
                      if st.last_frame_time else "none")
            lt = lt.replace("&", "&amp;").replace("<", "&lt;")
            page = ("<html><body><h3>Groove Coach debuglink</h3><p>Last telemetry: <code>%s</code></p>"
                    "<p>Last frame: %s</p><p>Tuning sha256: %s</p></body></html>"
                    % (lt, lf, good[1] if good else "none"))
            self._reply(200, page.encode("utf-8"), "text/html; charset=utf-8")
        else:
            self._reply(404, b"not found", "text/plain")


def make_server(host, port, data_dir, tuning_path=DEFAULT_TUNING, watch=()):
    state = State(data_dir, tuning_path, watch)
    handler = type("BoundHandler", (Handler,), {"state": state})
    srv = ThreadingHTTPServer((host, port), handler)
    srv.daemon_threads = True
    srv.state = state
    return srv


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--data", default=str(default_data_dir()))
    ap.add_argument("--tuning", default=str(DEFAULT_TUNING))
    ap.add_argument("--watch", default="", help="comma-separated extra telemetry keys to print")
    a = ap.parse_args()
    srv = make_server("0.0.0.0", a.port, a.data, a.tuning, a.watch.split(","))
    print("debuglink listening on port %d (no auth, LAN debug only)" % a.port)
    print("data dir: %s" % srv.state.data)
    for ip in lan_addresses():
        print("  enter in app: %s:%d" % (ip, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
