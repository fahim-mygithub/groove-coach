"""Per-joint tolerances from golden-performance variance, with verdicts and correction hints.

Mirror of ios/GrooveCore/Sources/GrooveCore/JointTolerance.swift (same defaults and algorithm).
Frames are dicts mapping joint name -> [x, y, z]. Hint convention: +x right, +y up, +z toward viewer.
tolerance = clamp(k * population stddev, floor, ceiling).
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence

Frame = Dict[str, Sequence[float]]

DEFAULT_CONFIG: Dict[str, float] = {
    "k": 2.0,
    "position_floor": 0.03,
    "position_ceiling": 0.25,
    "angle_floor_deg": 5.0,
    "angle_ceiling_deg": 45.0,
    "warn_factor": 2.0,
}

DEFAULT_ANGLE_TRIPLES: List[Dict[str, str]] = [
    {"name": "leftKnee", "parent": "leftHip", "joint": "leftKnee", "child": "leftAnkle"},
    {"name": "rightKnee", "parent": "rightHip", "joint": "rightKnee", "child": "rightAnkle"},
    {"name": "leftElbow", "parent": "leftShoulder", "joint": "leftElbow", "child": "leftWrist"},
    {"name": "rightElbow", "parent": "rightShoulder", "joint": "rightElbow", "child": "rightWrist"},
]


def _cfg(config: Optional[Dict[str, float]]) -> Dict[str, float]:
    merged = dict(DEFAULT_CONFIG)
    if config:
        merged.update(config)
    return merged


def _clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def _point(frame: Frame, name: str) -> Optional[List[float]]:
    c = frame.get(name)
    if c is None or len(c) < 3:
        return None
    return [float(c[0]), float(c[1]), float(c[2])]


def _angle_deg(frame: Frame, t: Dict[str, str]) -> Optional[float]:
    a, b, c = _point(frame, t["parent"]), _point(frame, t["joint"]), _point(frame, t["child"])
    if a is None or b is None or c is None:
        return None
    u = [a[i] - b[i] for i in range(3)]
    v = [c[i] - b[i] for i in range(3)]
    nu = math.sqrt(sum(x * x for x in u))
    nv = math.sqrt(sum(x * x for x in v))
    if nu < 1e-9 or nv < 1e-9:
        return None
    cosine = max(-1.0, min(1.0, sum(u[i] * v[i] for i in range(3)) / (nu * nv)))
    return math.acos(cosine) * 180.0 / math.pi


def _severity(err: float, tol: float, warn_factor: float) -> str:
    if err <= tol:
        return "ok"
    if err <= warn_factor * tol:
        return "warn"
    return "off"


def _words(name: str) -> str:
    return "".join(" " + ch.lower() if ch.isupper() else ch for ch in name)


def _hint(joint: str, d: Sequence[float]) -> str:
    ax, ay, az = abs(d[0]), abs(d[1]), abs(d[2])
    w = _words(joint)
    if ay >= ax and ay >= az:
        return ("raise " if d[1] > 0 else "lower ") + w
    if ax >= az:
        return "move " + w + (" right" if d[0] > 0 else " left")
    return "move " + w + (" forward" if d[2] > 0 else " back")


def position_tolerances(references: Sequence[Frame], config: Optional[Dict[str, float]] = None) -> Dict[str, float]:
    """Per-joint tolerance from aligned frames (one per golden performance)."""
    cfg = _cfg(config)
    out: Dict[str, float] = {}
    names = set()
    for f in references:
        names.update(f.keys())
    for name in names:
        pts = [p for p in (_point(f, name) for f in references) if p is not None]
        if not pts:
            continue
        n = float(len(pts))
        m = [sum(p[i] for p in pts) / n for i in range(3)]
        var = sum(sum((p[i] - m[i]) ** 2 for i in range(3)) for p in pts) / n
        out[name] = _clamp(cfg["k"] * math.sqrt(var), cfg["position_floor"], cfg["position_ceiling"])
    return out


def angle_tolerances(
    references: Sequence[Frame],
    triples: Optional[Sequence[Dict[str, str]]] = None,
    config: Optional[Dict[str, float]] = None,
) -> Dict[str, float]:
    """Per-joint-angle tolerance in degrees."""
    cfg = _cfg(config)
    out: Dict[str, float] = {}
    for t in triples if triples is not None else DEFAULT_ANGLE_TRIPLES:
        angles = [a for a in (_angle_deg(f, t) for f in references) if a is not None]
        if not angles:
            continue
        n = float(len(angles))
        mean = sum(angles) / n
        var = sum((a - mean) ** 2 for a in angles) / n
        out[t["name"]] = _clamp(cfg["k"] * math.sqrt(var), cfg["angle_floor_deg"], cfg["angle_ceiling_deg"])
    return out


def evaluate(
    learner: Frame,
    reference: Frame,
    tolerances: Dict[str, float],
    config: Optional[Dict[str, float]] = None,
) -> List[Dict[str, Any]]:
    """Verdicts {joint, error, tolerance, severity, direction, hint}, sorted by joint name."""
    cfg = _cfg(config)
    out: List[Dict[str, Any]] = []
    for name in sorted(tolerances):
        l, r = _point(learner, name), _point(reference, name)
        if l is None or r is None:
            continue
        tol = tolerances[name]
        delta = [r[i] - l[i] for i in range(3)]
        err = math.sqrt(sum(x * x for x in delta))
        sev = _severity(err, tol, cfg["warn_factor"])
        if sev == "ok":
            direction, hint = [0.0, 0.0, 0.0], None
        else:
            direction = [x / err for x in delta] if err >= 1e-9 else [0.0, 0.0, 0.0]
            hint = _hint(name, delta)
        out.append({"joint": name, "error": err, "tolerance": tol, "severity": sev,
                    "direction": direction, "hint": hint})
    return out


def evaluate_angles(
    learner: Frame,
    reference: Frame,
    tolerances: Dict[str, float],
    triples: Optional[Sequence[Dict[str, str]]] = None,
    config: Optional[Dict[str, float]] = None,
) -> List[Dict[str, Any]]:
    """Angle verdicts {name, error, tolerance, severity, hint}, sorted by name."""
    cfg = _cfg(config)
    out: List[Dict[str, Any]] = []
    for t in sorted(triples if triples is not None else DEFAULT_ANGLE_TRIPLES, key=lambda x: x["name"]):
        tol = tolerances.get(t["name"])
        l, r = _angle_deg(learner, t), _angle_deg(reference, t)
        if tol is None or l is None or r is None:
            continue
        err = abs(l - r)
        sev = _severity(err, tol, cfg["warn_factor"])
        hint = None if sev == "ok" else ("open " if r > l else "bend ") + _words(t["name"])
        out.append({"name": t["name"], "error": err, "tolerance": tol, "severity": sev, "hint": hint})
    return out
