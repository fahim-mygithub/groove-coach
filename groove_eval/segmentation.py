"""Settle-after-move segmentation (dance 'hit' detection) for Groove Coach.

Per-frame motion energy is the torso-scale-normalised speed (torso lengths per second) of the chosen joints, averaged
over a short trailing window. Hysteresis turns the energy curve into hit events: a hit is a moment where motion drops
from moving (energy >= moving_threshold) to settled (energy < settle_threshold for at least min_settle_s).

Mirrors ios/GrooveCore/Sources/GrooveCore/MoveSegmenter.swift with identical defaults.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Optional, Sequence

DEFAULT_JOINTS = (
    "leftWrist",
    "rightWrist",
    "leftAnkle",
    "rightAnkle",
    "leftHeel",
    "rightHeel",
    "leftFootIndex",
    "rightFootIndex",
)

DEFAULT_WINDOW_S = 0.110
DEFAULT_MOVING_THRESHOLD = 1.0
DEFAULT_SETTLE_THRESHOLD = 0.4
DEFAULT_MIN_SETTLE_S = 0.115
DEFAULT_BEAT_TOLERANCE_MS = 100.0


def torso_scale(frames: Sequence[Dict[str, Any]]) -> float:
    """Mean root -> centerShoulder distance over frames having both joints; 1.0 when unavailable."""
    total = 0.0
    count = 0
    for frame in frames:
        joints = frame["joints"]
        root = joints.get("root")
        shoulder = joints.get("centerShoulder")
        if root is None or shoulder is None:
            continue
        d = math.sqrt(sum((float(shoulder[k]) - float(root[k])) ** 2 for k in range(3)))
        total += d
        count += 1
    if count == 0:
        return 1.0
    mean = total / count
    return mean if mean > 0.0 else 1.0


def motion_energy(
    frames: Sequence[Dict[str, Any]],
    joint_names: Sequence[str] = DEFAULT_JOINTS,
    window_s: float = DEFAULT_WINDOW_S,
) -> List[float]:
    """Per-frame energy: mean over available joints of |p_i - p_j| / (t_i - t_j) / torso_scale.

    j is the earliest earlier frame with t_j >= t_i - window_s (at least one frame back). Frame 0 has energy 0.
    """
    scale = torso_scale(frames)
    energies = [0.0] * len(frames)
    for i in range(1, len(frames)):
        t_i = float(frames[i]["t"])
        j = i - 1
        while j > 0 and float(frames[j - 1]["t"]) >= t_i - window_s:
            j -= 1
        dt = t_i - float(frames[j]["t"])
        if dt <= 0.0:
            continue
        total = 0.0
        count = 0
        for name in joint_names:
            a = frames[j]["joints"].get(name)
            b = frames[i]["joints"].get(name)
            if a is None or b is None:
                continue
            dist = math.sqrt(sum((float(b[k]) - float(a[k])) ** 2 for k in range(3)))
            total += dist / dt / scale
            count += 1
        if count > 0:
            energies[i] = total / count
    return energies


def detect_hits(
    frames: Sequence[Dict[str, Any]],
    joint_names: Sequence[str] = DEFAULT_JOINTS,
    window_s: float = DEFAULT_WINDOW_S,
    moving_threshold: float = DEFAULT_MOVING_THRESHOLD,
    settle_threshold: float = DEFAULT_SETTLE_THRESHOLD,
    min_settle_s: float = DEFAULT_MIN_SETTLE_S,
) -> List[Dict[str, float]]:
    """Return hit events {timestamp, peakSpeed, settleDuration}.

    timestamp is the first settled frame; settleDuration is the settled time at the frame that confirmed the hit.
    Motion still in progress, or a settle shorter than min_settle_s at clip end, produces no hit.
    """
    energies = motion_energy(frames, joint_names, window_s)
    hits: List[Dict[str, float]] = []
    moving = False
    peak = 0.0
    settle_start: Optional[float] = None
    for frame, energy in zip(frames, energies):
        t = float(frame["t"])
        if not moving:
            if energy >= moving_threshold:
                moving = True
                peak = energy
                settle_start = None
            continue
        if energy >= settle_threshold:
            peak = max(peak, energy)
            settle_start = None
            continue
        if settle_start is None:
            settle_start = t
        if t - settle_start >= min_settle_s:
            hits.append({"timestamp": settle_start, "peakSpeed": peak, "settleDuration": t - settle_start})
            moving = False
            peak = 0.0
            settle_start = None
    return hits


def pair_hits_to_beats(
    hits: Sequence[Dict[str, float]],
    beats: Sequence[float],
    tolerance_ms: float = DEFAULT_BEAT_TOLERANCE_MS,
) -> List[Dict[str, float]]:
    """Pair each hit with the nearest beat within tolerance_ms (earlier beat wins ties).

    Returns {hitTimestamp, beatTimestamp, offsetMs} for matched hits only; offsetMs = (hit - beat) * 1000, so
    positive means the hit landed late.
    """
    pairs: List[Dict[str, float]] = []
    for hit in hits:
        best: Optional[float] = None
        best_abs = math.inf
        for beat in beats:
            d = abs(float(hit["timestamp"]) - float(beat))
            if d < best_abs:
                best_abs = d
                best = float(beat)
        if best is None:
            continue
        offset_ms = (float(hit["timestamp"]) - best) * 1000.0
        if abs(offset_ms) <= tolerance_ms:
            pairs.append({"hitTimestamp": float(hit["timestamp"]), "beatTimestamp": best, "offsetMs": offset_ms})
    return pairs
