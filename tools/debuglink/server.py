#!/usr/bin/env python3
"""Groove Coach debug link server (LAN debug only, no auth). Stdlib only; Bonjour via `zeroconf` if installed.

python tools/debuglink/server.py --port 8765 --data <dir> [--tuning <path>] [--watch k1,k2] [--no-bonjour]

The app finds this server by itself: Bonjour `_groovedebug._tcp` (when `zeroconf` is importable), otherwise a
`GET /health` probe across the phone's /24 subnet. Open http://localhost:8765/ for the live page.
"""
import argparse
import collections
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

MAX_BODY = 8 * 1024 * 1024
KEEP_FRAMES = 200
KEEP_SCREENS = 300
TAIL_LINES = 2000
DEFAULT_TUNING = Path(__file__).resolve().parent / "tuning.json"
SERVICE_TYPE = "_groovedebug._tcp.local."
HEALTH_HEADER = "X-Groove-Debuglink"
PROTOCOL_VERSION = "2"


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
    return sorted(a for a in addrs if not a.startswith("127.") and not a.startswith("169.254."))


def _day(ts):
    return datetime.fromtimestamp(ts).strftime("%Y%m%d")


def _write_replace(path, data):
    """Write via a temp file + replace; on Windows a reader holding the file can make replace fail, so retry."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    for _ in range(5):
        try:
            os.replace(tmp, path)
            return
        except OSError:
            time.sleep(0.02)
    try:
        tmp.unlink()
    except OSError:
        pass


class State:
    def __init__(self, data_dir, tuning_path, watch):
        self.data = Path(data_dir)
        self.frames = self.data / "frames"
        self.screens = self.data / "screen"
        self.frames.mkdir(parents=True, exist_ok=True)
        self.screens.mkdir(parents=True, exist_ok=True)
        self.tuning_path = Path(tuning_path)
        self.watch = [k for k in watch if k]
        self.lock = threading.Lock()
        self.last_telemetry = None
        self.last_frame_time = None
        self.last_good = None  # (bytes, etag)
        self.frame_seq = 0
        self.screen_seq = 0
        self.external_screen_seq = 0
        self.screen_files = collections.deque(sorted(self.screens.glob("screen-*.jpg")))
        self.external_screen_files = collections.deque(sorted(self.screens.glob("external-*.jpg")))
        self.latest_screen = None  # (bytes, label, ts)
        self.latest_external_screen = None  # (bytes, label, ts)
        self.screen_times = collections.deque(maxlen=20)
        self.external_screen_times = collections.deque(maxlen=20)
        self.log_tail = collections.deque(maxlen=TAIL_LINES)
        self.event_tail = collections.deque(maxlen=500)
        self.device = None
        self.device_ip = None
        self.last_seen = None
        self.last_error = None
        self.counts = collections.Counter()
        self.bonjour = "off"

    # --- shared bookkeeping (call with the lock held)

    def _seen(self, client_ip, device=None):
        self.last_seen = time.time()
        self.device_ip = client_ip
        if device:
            self.device = device

    @staticmethod
    def _fps(times, now):
        recent = [t for t in times if now - t <= 10]
        if len(recent) >= 2:
            span = recent[-1] - recent[0]
            return round((len(recent) - 1) / span, 2) if span > 0 else 0.0
        return 0.0

    def _status_locked(self):
        now = time.time()
        fps = self._fps(self.screen_times, now)
        external_fps = self._fps(self.external_screen_times, now)
        return {
            "device": self.device,
            "device_ip": self.device_ip,
            "connected": bool(self.last_seen and now - self.last_seen < 10),
            "last_seen": self.last_seen,
            "last_seen_iso": datetime.fromtimestamp(self.last_seen).isoformat() if self.last_seen else None,
            "fps": fps,
            "external_fps": external_fps,
            "last_error": self.last_error,
            "counts": dict(self.counts),
            "latest_screen": self.latest_screen[1] if self.latest_screen else None,
            "latest_external_screen": self.latest_external_screen[1] if self.latest_external_screen else None,
            "bonjour": self.bonjour,
            "updated": now,
        }

    def _write_status_locked(self):
        try:
            _write_replace(self.data / "status.json",
                           json.dumps(self._status_locked(), indent=1).encode("utf-8"))
        except OSError:
            pass

    def status(self):
        with self.lock:
            return self._status_locked()

    def _append_jsonl(self, name, items):
        with open(self.data / name, "a", encoding="utf-8") as f:
            for it in items:
                f.write(json.dumps(it, separators=(",", ":")) + "\n")

    # --- tuning

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

    # --- calibration telemetry / frames (unchanged formats)

    def add_telemetry(self, items, client_ip=None):
        now = time.time()
        with self.lock:
            for it in items:
                it["recv_ts"] = now
            self._append_jsonl("telemetry-%s.jsonl" % _day(now), items)
            for it in items:
                self.last_telemetry = it
                keys = ["step", "cue"] + self.watch
                print(" ".join("%s=%s" % (k, it[k]) for k in keys if k in it) or "(telemetry)", flush=True)
            self.counts["telemetry"] += len(items)
            self._seen(client_ip, items[-1].get("deviceModel") if items else None)

    def add_frame(self, body, label, client_ip=None):
        with self.lock:
            self.frame_seq += 1
            now = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            _write_replace(self.frames / "latest.jpg", body)
            (self.frames / ("frame-%s-%d.jpg" % (now, self.frame_seq))).write_bytes(body)
            old = sorted(self.frames.glob("frame-*.jpg"))
            for p in old[:-KEEP_FRAMES]:
                try:
                    p.unlink()
                except OSError:
                    pass
            self.last_frame_time = time.time()
            self.counts["frame"] += 1
            self._seen(client_ip)
        print("frame saved%s" % (" [%s]" % label if label else ""), flush=True)

    # --- logs / events / screen

    def add_logs(self, lines, device=None, client_ip=None):
        now = time.time()
        with self.lock:
            for ln in lines:
                ln["recv_ts"] = now
                if device and "device" not in ln:
                    ln["device"] = device
                self.log_tail.append(ln)
                if str(ln.get("level", "")).lower() in ("error", "fault", "crash"):
                    self.last_error = {"ts": ln.get("ts", now), "msg": str(ln.get("msg", ""))[:500],
                                       "where": ln.get("file")}
            self._append_jsonl("logs-%s.jsonl" % _day(now), lines)
            self.counts["log"] += len(lines)
            self._seen(client_ip, device)
            self._write_status_locked()
        for ln in lines:
            lvl = str(ln.get("level", "info"))
            if lvl.lower() != "debug":
                print("[%s] %s" % (lvl, str(ln.get("msg", ""))[:300]), flush=True)

    def add_events(self, items, client_ip=None):
        now = time.time()
        with self.lock:
            for it in items:
                it["recv_ts"] = now
                self.event_tail.append(it)
                if it.get("kind") == "crash":
                    self.last_error = {"ts": it.get("ts", now), "msg": "crash: %s" % it.get("reason", "?")}
            self._append_jsonl("events-%s.jsonl" % _day(now), items)
            self.counts["event"] += len(items)
            self._seen(client_ip, items[-1].get("deviceModel") if items else None)
            self._write_status_locked()
        for it in items:
            extra = it.get("screen") or it.get("name") or it.get("reason") or ""
            print("event %s %s" % (it.get("kind", "?"), extra), flush=True)

    def add_screen(self, body, label, client_ip=None, device=None, role=None):
        ts = time.time()
        norm_role = "external" if (role or "").strip().lower() == "external" else "phone"
        with self.lock:
            stamp = datetime.fromtimestamp(ts).strftime("%Y%m%d-%H%M%S-%f")
            if norm_role == "external":
                self.external_screen_seq += 1
                path = self.screens / ("external-%s-%06d.jpg" % (stamp, self.external_screen_seq))
                path.write_bytes(body)
                self.external_screen_files.append(path)
                while len(self.external_screen_files) > KEEP_SCREENS:
                    old = self.external_screen_files.popleft()
                    try:
                        old.unlink()
                    except OSError:
                        pass
                _write_replace(self.screens / "latest-external.jpg", body)
                self.latest_external_screen = (body, label, ts)
                self.external_screen_times.append(ts)
                self.counts["external_screen"] += 1
            else:
                self.screen_seq += 1
                path = self.screens / ("screen-%s-%06d.jpg" % (stamp, self.screen_seq))
                path.write_bytes(body)
                self.screen_files.append(path)
                while len(self.screen_files) > KEEP_SCREENS:
                    old = self.screen_files.popleft()
                    try:
                        old.unlink()
                    except OSError:
                        pass
                _write_replace(self.screens / "latest.jpg", body)
                self.latest_screen = (body, label, ts)
                self.screen_times.append(ts)
                self.counts["screen"] += 1
            self._seen(client_ip, device)
            self._write_status_locked()

    def tails(self, n):
        with self.lock:
            logs = list(self.log_tail)[-n:]
            events = list(self.event_tail)[-min(n, 100):]
        return logs, events


LIVE_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Groove Coach debuglink</title>
<style>
body{margin:0;font:13px system-ui,sans-serif;background:#111;color:#ddd;display:flex;height:100vh}
#left{flex:0 0 auto;padding:8px;display:flex;flex-direction:column;align-items:center;gap:6px}
#screens{display:flex;gap:8px;align-items:flex-start}
#scr{max-height:calc(100vh - 60px);max-width:25vw;border:1px solid #333;background:#000}
#scr-tv{max-height:calc(100vh - 60px);max-width:35vw;border:1px solid #333;background:#000;display:none}
#right{flex:1;display:flex;flex-direction:column;min-width:0;padding:8px}
#status{white-space:pre-wrap;font:12px monospace;color:#9cf;margin-bottom:6px}
#log{flex:1;overflow:auto;font:12px monospace;white-space:pre-wrap;background:#000;padding:6px;border:1px solid #333}
#ev{height:22%;overflow:auto;font:12px monospace;white-space:pre-wrap;background:#000;padding:6px;margin-top:6px;border:1px solid #333}
.error,.crash,.fault{color:#f66}.warn{color:#fc6}.debug{color:#888}.stderr{color:#f9a}.stdout{color:#aaa}
</style></head><body>
<div id="left"><div id="screens"><img id="scr" alt="no screen yet"><img id="scr-tv" alt="no external screen yet"></div><div id="cap"></div></div>
<div id="right"><div id="status">connecting...</div><div id="log"></div><div id="ev"></div></div>
<script>
const esc=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;');
const fmt=t=>t?new Date(t*1000).toLocaleTimeString():'';
let follow=true;const L=document.getElementById('log');
L.addEventListener('scroll',()=>{follow=L.scrollTop+L.clientHeight>=L.scrollHeight-20});
async function tick(){
  try{
    const st=await (await fetch('/status.json',{cache:'no-store'})).json();
    document.getElementById('status').textContent=
      (st.connected?'CONNECTED ':'disconnected ')+(st.device||'?')+' @ '+(st.device_ip||'?')+
      '  fps '+st.fps+'  ext_fps '+(st.external_fps||0)+'  last seen '+fmt(st.last_seen)+
      '  screen ['+(st.latest_screen||'')+']'+(st.latest_external_screen?'  tv ['+st.latest_external_screen+']':'')+
      '  bonjour '+st.bonjour+(st.last_error?'\\nlast error: '+st.last_error.msg:'');
    if(st.counts&&st.counts.screen){document.getElementById('scr').src='/screen/latest.jpg?n='+st.counts.screen;}
    if(st.counts&&st.counts.external_screen){const tv=document.getElementById('scr-tv');tv.style.display='block';tv.src='/screen/latest-external.jpg?n='+st.counts.external_screen;}
    const t=await (await fetch('/tail.json?n=400',{cache:'no-store'})).json();
    L.innerHTML=t.logs.map(l=>'<div class="'+esc(l.level||'')+'">'+fmt(l.ts)+' '+esc(l.level||'')+' '+
      (l.file?esc(l.file)+':'+(l.line||'')+' ':'')+esc(l.msg||'')+'</div>').join('');
    if(follow)L.scrollTop=L.scrollHeight;
    const E=document.getElementById('ev');
    E.innerHTML=t.events.slice().reverse().map(e=>'<div class="'+esc(e.kind||'')+'">'+fmt(e.ts)+' '+
      esc(e.kind||'')+' '+esc(JSON.stringify(e).slice(0,400))+'</div>').join('');
  }catch(e){document.getElementById('status').textContent='server unreachable: '+e;}
}
tick();setInterval(tick,1000);
</script></body></html>
"""


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
            left = min(n, 4 * MAX_BODY)
            while left > 0:
                chunk = self.rfile.read(min(65536, left))
                if not chunk:
                    break
                left -= len(chunk)
            self.close_connection = True
            self._reply(413, b"too large", "text/plain", {"Connection": "close"})
            return None
        return self.rfile.read(n)

    def _json_body(self, body):
        try:
            return json.loads(body.decode("utf-8"))
        except ValueError:
            self._reply(400, b"invalid json", "text/plain")
            return None

    def do_POST(self):
        path = self.path.split("?")[0]
        if path not in ("/telemetry", "/frame", "/log", "/event", "/screen"):
            self.close_connection = True
            self._reply(404, b"not found", "text/plain", {"Connection": "close"})
            return
        body = self._read_body()
        if body is None:
            return
        ip = self.client_address[0]
        st = self.state
        if path in ("/telemetry", "/event"):
            obj = self._json_body(body)
            if obj is None:
                return
            items = obj if isinstance(obj, list) else [obj]
            if not all(isinstance(i, dict) for i in items):
                self._reply(400, b"expected object(s)", "text/plain")
                return
            if path == "/telemetry":
                st.add_telemetry(items, ip)
            else:
                st.add_events(items, ip)
        elif path == "/log":
            obj = self._json_body(body)
            if obj is None:
                return
            # {"device": ..., "lines": [...]} or a bare list of line objects.
            device = obj.get("device") if isinstance(obj, dict) else None
            lines = obj.get("lines") if isinstance(obj, dict) else obj
            if not isinstance(lines, list) or not all(isinstance(i, dict) for i in lines):
                self._reply(400, b"expected lines", "text/plain")
                return
            st.add_logs(lines, device, ip)
        elif path == "/screen":
            if not body:
                self._reply(400, b"empty", "text/plain")
                return
            st.add_screen(body, self.headers.get("X-Screen-Name"), ip,
                          self.headers.get("X-Device"), self.headers.get("X-Screen-Role"))
        else:
            st.add_frame(body, self.headers.get("X-Frame-Label"), ip)
        self._reply(204)

    def do_GET(self):
        raw_path, _, query = self.path.partition("?")
        path = raw_path
        st = self.state
        if path == "/health":
            self._reply(200, b"ok", "text/plain", {HEALTH_HEADER: PROTOCOL_VERSION})
        elif path == "/tuning.json":
            raw, etag = st.tuning() or (b"{}", hashlib.sha256(b"{}").hexdigest())
            tag = '"%s"' % etag
            if self.headers.get("If-None-Match", "").strip() == tag:
                self._reply(304, headers={"ETag": tag})
            else:
                self._reply(200, raw, "application/json", {"ETag": tag})
        elif path == "/status.json":
            self._reply(200, json.dumps(st.status()).encode("utf-8"), "application/json",
                        {"Cache-Control": "no-store"})
        elif path == "/tail.json":
            n = 200
            for part in query.split("&"):
                if part.startswith("n="):
                    try:
                        n = max(1, min(TAIL_LINES, int(part[2:])))
                    except ValueError:
                        pass
            logs, events = st.tails(n)
            self._reply(200, json.dumps({"logs": logs, "events": events}).encode("utf-8"),
                        "application/json", {"Cache-Control": "no-store"})
        elif path == "/screen/latest.jpg":
            with st.lock:
                latest = st.latest_screen
            if latest is None:
                self._reply(404, b"no screen yet", "text/plain")
            else:
                self._reply(200, latest[0], "image/jpeg", {"Cache-Control": "no-store"})
        elif path == "/screen/latest-external.jpg":
            with st.lock:
                latest = st.latest_external_screen
            if latest is None:
                self._reply(404, b"no external screen yet", "text/plain")
            else:
                self._reply(200, latest[0], "image/jpeg", {"Cache-Control": "no-store"})
        elif path == "/":
            self._reply(200, LIVE_PAGE.encode("utf-8"), "text/html; charset=utf-8")
        else:
            self._reply(404, b"not found", "text/plain")


def make_server(host, port, data_dir, tuning_path=DEFAULT_TUNING, watch=()):
    state = State(data_dir, tuning_path, watch)
    handler = type("BoundHandler", (Handler,), {"state": state})
    srv = ThreadingHTTPServer((host, port), handler)
    srv.daemon_threads = True
    srv.state = state
    return srv


def start_bonjour(port, addresses, state=None):
    """Advertise `_groovedebug._tcp` if `zeroconf` is installed. Returns a stop() callable, or None."""
    try:
        from zeroconf import ServiceInfo, Zeroconf  # optional dependency
    except ImportError:
        if state is not None:
            state.bonjour = "unavailable (pip install zeroconf)"
        return None
    try:
        name = "GrooveDebug-%s" % socket.gethostname().split(".")[0]
        info = ServiceInfo(
            SERVICE_TYPE,
            "%s.%s" % (name, SERVICE_TYPE),
            addresses=[socket.inet_aton(a) for a in addresses],
            port=port,
            properties={"ips": ",".join(addresses), "port": str(port), "v": PROTOCOL_VERSION},
            server="%s.local." % name,
        )
        zc = Zeroconf()
        zc.register_service(info, allow_name_change=True)
    except Exception as e:  # noqa: BLE001 - Bonjour is best effort; the subnet probe still works.
        print("WARN: Bonjour advertise failed: %s" % e, file=sys.stderr, flush=True)
        if state is not None:
            state.bonjour = "failed: %s" % e
        return None
    if state is not None:
        state.bonjour = "on"

    def stop():
        try:
            zc.unregister_service(info)
            zc.close()
        except Exception:  # noqa: BLE001
            pass
    return stop


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--data", default=str(default_data_dir()))
    ap.add_argument("--tuning", default=str(DEFAULT_TUNING))
    ap.add_argument("--watch", default="", help="comma-separated extra telemetry keys to print")
    ap.add_argument("--no-bonjour", action="store_true", help="do not advertise _groovedebug._tcp")
    a = ap.parse_args()
    srv = make_server("0.0.0.0", a.port, a.data, a.tuning, a.watch.split(","))
    addrs = lan_addresses()
    stop_bonjour = None if a.no_bonjour else start_bonjour(a.port, addrs, srv.state)
    print("debuglink listening on port %d (no auth, LAN debug only)" % a.port)
    print("data dir: %s" % srv.state.data)
    print("bonjour: %s" % srv.state.bonjour)
    print("live page: http://localhost:%d/" % a.port)
    for ip in addrs:
        print("  phone finds it by itself; manual override: %s:%d" % (ip, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if stop_bonjour:
            stop_bonjour()


if __name__ == "__main__":
    main()
