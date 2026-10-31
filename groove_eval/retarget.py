"""Bone-length retargeting of a reference onto the learner's proportions (owner decision Q3, spec §8; v1 path B of
the body-extrapolation report: MediaPipe skeleton only, no mesh model).

Mirror of ios/GrooveCore/Sources/GrooveCore/Retarget.swift (same bone table, same operation order).

The teacher's motion is kept as unit bone directions and re-walked from `root` along `CANONICAL_BONES` with the
learner's bone lengths:

    x_child = x_parent + L_learner(child) * unit(teacher_child - teacher_parent)

`root` keeps the teacher's position, so the result is a canonical frame of the same shape (canonical -> canonical).
Joint angles are invariant to this step; joint positions (and anything normalised by leg length) are not, which is
what lets a long-armed learner match a short-armed teacher.

Learner lengths are the per-bone median over a calibration stance when the take carries one
(`attempt_clip["calibration_frames"]`), else over the take itself. Bones the learner frames never show keep the
teacher's length. Hand landmarks move with their wrist.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from groove_eval.canonical_skeleton import CANONICAL_BONES

Vec3 = Tuple[float, float, float]


def _point(joints: Mapping[str, Any], name: str) -> Optional[Vec3]:
    p = joints.get(name)
    if p is None or len(p) < 3:
        return None
    return (float(p[0]), float(p[1]), float(p[2]))


def _length(a: Vec3, b: Vec3) -> float:
    dx, dy, dz = a[0] - b[0], a[1] - b[1], a[2] - b[2]
    return math.sqrt(dx * dx + dy * dy + dz * dz)


def _median(values: Sequence[float]) -> float:
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) * 0.5


def mirror_name(name: str) -> str:
    """leftX <-> rightX (the MIRROR_SWAP_PAIRS rule); other joint names are unchanged."""
    if name.startswith("left"):
        return "right" + name[4:]
    if name.startswith("right"):
        return "left" + name[5:]
    return name


def median_bone_lengths(frames: Sequence[Mapping[str, Any]]) -> Dict[str, float]:
    """Per-bone median length (m) over `frames`, keyed by the bone's child joint (as `canonical_skeleton.bone_lengths`)."""
    samples: Dict[str, List[float]] = {}
    for frame in frames:
        joints = frame["joints"]
        for child, parent in CANONICAL_BONES:
            c, p = _point(joints, child), _point(joints, parent)
            if c is None or p is None:
                continue
            samples.setdefault(child, []).append(_length(c, p))
    return {child: _median(vals) for child, vals in samples.items()}


def learner_bone_lengths(attempt_clip: Mapping[str, Any]) -> Dict[str, float]:
    """The learner's bone lengths in the reference's side labels.

    From `calibration_frames` (a calibration stance) when present and non-empty, else from the take's frames. A
    mirrored take's left/right labels are swapped, like `scoring._swap_mirrored` does for its joints.
    """
    frames = attempt_clip.get("calibration_frames") or attempt_clip["frames"]
    lengths = median_bone_lengths(frames)
    if bool(attempt_clip.get("mirrored", False)):
        lengths = {mirror_name(k): v for k, v in lengths.items()}
    return lengths


def retarget_frame(frame: Mapping[str, Any], lengths: Mapping[str, float]) -> Dict[str, Any]:
    """One canonical frame re-walked with `lengths`; joints the walk cannot reach (missing parent) are kept as-is."""
    joints = frame["joints"]
    root = _point(joints, "root")
    if root is None:
        return dict(frame)
    walked: Dict[str, Vec3] = {"root": root}
    for child, parent in CANONICAL_BONES:
        c, p = _point(joints, child), _point(joints, parent)
        base = walked.get(parent)
        if c is None or p is None or base is None:
            continue
        length = lengths.get(child)
        if length is None:
            walked[child] = (base[0] + (c[0] - p[0]), base[1] + (c[1] - p[1]), base[2] + (c[2] - p[2]))
            continue
        n = _length(c, p)
        if n < 1e-9:
            walked[child] = base
            continue
        d = ((c[0] - p[0]) / n, (c[1] - p[1]) / n, (c[2] - p[2]) / n)
        walked[child] = (base[0] + d[0] * length, base[1] + d[1] * length, base[2] + d[2] * length)

    out_joints: Dict[str, Any] = dict(joints)
    for name, p in walked.items():
        out_joints[name] = [p[0], p[1], p[2]]
    out = dict(frame)
    out["joints"] = out_joints

    hands = frame.get("hands")
    if hands:
        moved: Dict[str, Any] = {}
        for side, pts in hands.items():
            old, new = _point(joints, side + "Wrist"), walked.get(side + "Wrist")
            if old is None or new is None:
                moved[side] = pts
                continue
            sx, sy, sz = new[0] - old[0], new[1] - old[1], new[2] - old[2]
            moved[side] = [
                [float(q[0]) + sx, (float(q[1]) if len(q) > 1 else 0.0) + sy, (float(q[2]) if len(q) > 2 else 0.0) + sz]
                for q in pts
            ]
        out["hands"] = moved
    return out


def retarget_frames(frames: Sequence[Mapping[str, Any]], lengths: Mapping[str, float]) -> List[Dict[str, Any]]:
    return [retarget_frame(f, lengths) for f in frames]


def retarget_clip(clip: Mapping[str, Any], lengths: Mapping[str, float]) -> Dict[str, Any]:
    """A copy of a PoseClip whose frames are retargeted onto `lengths` (all other fields kept)."""
    out = dict(clip)
    out["frames"] = retarget_frames(clip["frames"], lengths)
    return out
