# debuglink

PC side of the app's Debug Link: a live, app-wide connection from the iPhone to this PC over Wi-Fi, so the agent
(and you) can follow what the app is doing without screenshots.

**No authentication.** LAN debug use only; do not expose it to untrusted networks.

## Start (nothing to configure)

    powershell -ExecutionPolicy Bypass -File tools\debuglink\start.ps1

`start.ps1` adds the inbound firewall rules if they are missing (TCP 8765 and UDP 5353 for Bonjour, Private + Public
profiles; without admin rights it prints the command to run once in an elevated shell), installs the optional
`zeroconf` package for Bonjour (`-NoInstall` to skip), and starts the server. Options: `-Port`, `-Data <dir>`,
`-NoBonjour`.

The app has the Debug Link **on by default** and finds the PC by itself:

1. the last host that worked;
2. Bonjour `_groovedebug._tcp` (advertised when `zeroconf` is importable; the TXT record carries the PC's IPv4s);
3. otherwise a `GET /health` probe across the phone's /24 (24 at a time, 0.8 s timeouts; ~10 s worst case).

It reconnects by itself after Wi-Fi drops or a server restart. A host typed in Courses > gear overrides discovery;
the same screen has the off switch. On first use iOS shows the **Local Network** prompt: allow it.

Direct start (stdlib only; Bonjour only if `zeroconf` is installed):

    python tools/debuglink/server.py --port 8765 --data <dir> [--tuning <path>] [--watch k1,k2] [--no-bonjour]

Default data dir: `%LOCALAPPDATA%\groove-coach\debuglink` (`~/.groove-coach/debuglink` off Windows).

## What arrives

| Endpoint | From the app | Written under the data dir |
| --- | --- | --- |
| `POST /screen` | full-resolution JPEG of the screen (~1/s, q 0.7; camera preview composited in), `X-Screen-Name` | `screen/latest.jpg` + the newest 300 `screen/screen-*.jpg` |
| `POST /log` | `{"device", "appBuild", "dropped"?, "lines": [{ts, level, msg, file?, line?, seq}]}`; levels `debug/info/warn/error/stdout/stderr` (stdout/stderr are captured) | `logs-YYYYMMDD.jsonl` |
| `POST /event` | list of `{kind, ts, screen, deviceModel, appBuild, ...}`: `app_launch`, `screen_appear`/`screen_disappear` (`name`), `app_active`/`app_inactive`/`app_foreground`/`app_background`, `memory_warning`, `take_end`, `calibration_end`, `crash` (`reason`, `stack`, `log` = last 200 lines, sent on the launch after the crash) | `events-YYYYMMDD.jsonl` |
| `POST /telemetry` | calibration readings, ~2 Hz while calibrating | `telemetry-YYYYMMDD.jsonl` |
| `POST /frame` | annotated 360 px calibration camera JPEG every 3 s | `frames/latest.jpg` + newest 200 |

`status.json` (also `GET /status.json`): connected device + IP, last seen, screen fps, last error, counts.
Bodies over 8 MB get 413.

## Watch

- `GET /`: live page (latest screen, log tail, events; refreshes every second). Open http://localhost:8765/.
- `GET /screen/latest.jpg`, `GET /tail.json?n=200` (`{"logs": [...], "events": [...]}`), `GET /status.json`.
- Tail a file: `Get-Content <data>\logs-YYYYMMDD.jsonl -Wait -Tail 20`

## Tuning

Edit `tuning.json`; keys are the Swift property names in `CalibrationTuning.swift` and override the app defaults.
The phone polls `GET /tuning.json` (ETag/304) every 2 s during a calibration. If the file is invalid JSON, the last
valid copy is served and a warning is logged.

## Limits

- Lesson video (`AVPlayerLayer`) shows black in the screen frames; the camera preview is composited in.
- iOS suspends the app in the background, so nothing is sent there; buffered log lines (up to 4000) go out on return.
