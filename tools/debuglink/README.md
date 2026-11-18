# debuglink

PC-side server for live calibration tuning. The iPhone app sends readings (~2 Hz) to `/telemetry`, a small camera+overlay JPEG every few seconds to `/frame`, and polls `/tuning.json` (~2 s, ETag/304).

**No authentication.** LAN debug use only; do not expose it to untrusted networks.

## Start

    python tools/debuglink/server.py --port 8765 --data <dir>

Options: `--tuning <path>` (default `tools/debuglink/tuning.json`), `--watch k1,k2` (extra telemetry keys in the console summary). Default data dir: `%LOCALAPPDATA%\groove-coach\debuglink` (`~/.groove-coach/debuglink` off Windows). At start it prints the PC's LAN IPv4 addresses; type one (with the port) into the app.

Endpoints: `POST /telemetry`, `POST /frame` (optional `X-Frame-Label`), `GET /tuning.json`, `GET /` (status), `GET /health`. Bodies over 2 MB get 413. The newest 200 frames are kept; `frames/latest.jpg` is always the latest.

## Tuning

Edit `tuning.json`; keys are the Swift property names in `CalibrationTuning.swift` and override the app defaults. Edits apply live. If the file is invalid JSON, the last valid copy is served and a warning is logged.

## Windows firewall

The eero-amin Wi-Fi profile is currently Public. Either switch it to Private (Settings > Network & internet > Wi-Fi), or allow the port:

    New-NetFirewallRule -DisplayName "GrooveCoach debuglink" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Private

## Tail the log

    Get-Content <data>\telemetry-YYYYMMDD.jsonl -Wait -Tail 20

## iOS

On first connect iOS shows the **Local Network** permission prompt. Allow it, or the app cannot reach the PC.
