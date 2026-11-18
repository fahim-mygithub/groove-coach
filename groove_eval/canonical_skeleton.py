"""MediaPipe world landmarks -> canonical skeleton `groove.canonical/1` (spec §3.1).

Mirror of ios/GrooveCore/Sources/GrooveCore/CanonicalSkeleton.swift (M1, WO-1A): same joint table, same operation
order, so both sides produce bit-identical frames for `fixtures/mediapipe_sample_frames.json`.

Canonical frame convention (unchanged from the Vision 3D era, see `joint_tolerance.py`): metres, root-relative,
+x right, +y up, +z toward the viewer (the camera). MediaPipe world landmarks are hip-centred metres with
image-aligned axes (+x image right, +y down, smaller z closer to the camera), so the mapper keeps x and flips y and z,
the same `visionAxes` flip `FootKeypointProvider.swift` already uses. That is a proper rotation (no reflection), so
hand palm normals keep the `HandStyling` convention.

Operation order (the Swift port must match it exactly):
1. flip every landmark: (x, y, z) -> (x, -y, -z);
2. synthesize root = mid(23, 24), centerShoulder = mid(11, 12), spine = mid(root, centerShoulder),
   with mid(a, b) = ((a + b) * 0.5) per axis;
3. subtract root from every joint (root becomes exactly [0, 0, 0]).

Retargeting (owner decision Q3, spec §8): frames are plain Cartesian joint positions with a fixed bone table
(`CANONICAL_BONES`), so a later bone-length normalization step can run canonical -> canonical between the reference
and the learner without changing this mapping, the manifest or the scoring engine.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

SKELETON_ID = "groove.canonical/1"
MEDIAPIPE_POSE_LANDMARKS = 33
MEDIAPIPE_HAND_LANDMARKS = 21

# Canonical joint -> MediaPipe PoseLandmarker index.
MEDIAPIPE_INDEX: Dict[str, int] = {
    "nose": 0,
    "leftShoulder": 11,
    "rightShoulder": 12,
    "leftElbow": 13,
    "rightElbow": 14,
    "leftWrist": 15,
    "rightWrist": 16,
    "leftHip": 23,
    "rightHip": 24,
    "leftKnee": 25,
    "rightKnee": 26,
    "leftAnkle": 27,
    "rightAnkle": 28,
    "leftHeel": 29,
    "rightHeel": 30,
    "leftFootIndex": 31,
    "rightFootIndex": 32,
}

# Synthesized joint -> the MediaPipe indices it is built from (confidence = min visibility of those indices).
SYNTHESIZED_SOURCES: Dict[str, Tuple[int, ...]] = {
    "root": (23, 24),
    "centerShoulder": (11, 12),
    "spine": (11, 12, 23, 24),
}

# Output order (dicts keep insertion order; JSON fixtures and the Swift port use this order).
CANONICAL_JOINTS: Tuple[str, ...] = (
    "root",
    "spine",
    "centerShoulder",
    "leftHip",
    "leftKnee",
    "leftAnkle",
    "rightHip",
    "rightKnee",
    "rightAnkle",
    "leftShoulder",
    "leftElbow",
    "leftWrist",
    "rightShoulder",
    "rightElbow",
    "rightWrist",
    "leftHeel",
    "leftFootIndex",
    "rightHeel",
    "rightFootIndex",
    "nose",
)

# (child, parent) bones of the canonical tree rooted at `root`; the hook for a later retarget step.
CANONICAL_BONES: Tuple[Tuple[str, str], ...] = (
    ("spine", "root"),
    ("centerShoulder", "spine"),
    ("nose", "centerShoulder"),
    ("leftHip", "root"),
    ("leftKnee", "leftHip"),
    ("leftAnkle", "leftKnee"),
    ("leftHeel", "leftAnkle"),
    ("leftFootIndex", "leftAnkle"),
    ("rightHip", "root"),
    ("rightKnee", "rightHip"),
    ("rightAnkle", "rightKnee"),
    ("rightHeel", "rightAnkle"),
    ("rightFootIndex", "rightAnkle"),
    ("leftShoulder", "centerShoulder"),
    ("leftElbow", "leftShoulder"),
    ("leftWrist", "leftElbow"),
    ("rightShoulder", "centerShoulder"),
    ("rightElbow", "rightShoulder"),
    ("rightWrist", "rightElbow"),
)

Vec3 = List[float]


def mediapipe_axes(p: Sequence[float]) -> Vec3:
    """MediaPipe world axes (+y down, -z toward camera) -> canonical axes (+y up, +z toward camera)."""
    return [float(p[0]), -float(p[1]), -float(p[2])]


def _mid(a: Sequence[float], b: Sequence[float]) -> Vec3:
    return [(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5]


def _clamp01(x: float) -> float:
    return max(0.0, min(1.0, float(x)))


def _assign_hands(
    hands: Sequence[Mapping[str, Any]],
    image_landmarks: Sequence[Sequence[float]],
    image_aspect: float,
) -> Dict[str, int]:
    """Side -> hand index, by nearest pose wrist in image space (never by the handedness label).

    With two or more hands, the (left, right) pair with the smallest summed distance wins; ties keep the earlier
    pair in (i, j) order. A single hand goes to its nearer wrist (left on a tie).
    """
    wrists = {"left": image_landmarks[MEDIAPIPE_INDEX["leftWrist"]], "right": image_landmarks[MEDIAPIPE_INDEX["rightWrist"]]}

    def dist(hand_idx: int, side: str) -> float:
        h = hands[hand_idx]["image_landmarks"][0]
        w = wrists[side]
        dx = (float(h[0]) - float(w[0])) * image_aspect
        dy = float(h[1]) - float(w[1])
        return math.sqrt(dx * dx + dy * dy)

    if len(hands) == 1:
        return {"left": 0} if dist(0, "left") <= dist(0, "right") else {"right": 0}
    best: Optional[Tuple[float, int, int]] = None
    for i in range(len(hands)):
        for j in range(len(hands)):
            if i == j:
                continue
            total = dist(i, "left") + dist(j, "right")
            if best is None or total < best[0]:
                best = (total, i, j)
    assert best is not None
    return {"left": best[1], "right": best[2]}


def to_canonical(
    world_landmarks: Sequence[Sequence[float]],
    visibility: Sequence[float],
    hands: Optional[Sequence[Mapping[str, Any]]] = None,
    *,
    t: float = 0.0,
    image_landmarks: Optional[Sequence[Sequence[float]]] = None,
    image_aspect: float = 1.0,
) -> Dict[str, Any]:
    """One MediaPipe pose result -> one canonical `RawPoseFrame` (the `PoseClip` frame shape).

    `world_landmarks` / `visibility`: the 33 PoseLandmarker world landmarks and their visibility scores.
    `hands`: optional HandLandmarker results, each `{"world_landmarks": 21x3, "image_landmarks": 21x(2|3)}`.
    Assigning hands to sides needs the pose's normalized `image_landmarks` (33x(2|3)); `image_aspect` is the image
    width / height, so x and y distances are compared in the same pixel units.
    A hand's points are its world landmarks in canonical axes, placed as wrist + (p - p0), so landmark 0 sits
    exactly on that side's pose wrist.
    """
    if len(world_landmarks) != MEDIAPIPE_POSE_LANDMARKS or len(visibility) != MEDIAPIPE_POSE_LANDMARKS:
        raise ValueError(f"expected {MEDIAPIPE_POSE_LANDMARKS} pose landmarks and visibilities")

    flipped = [mediapipe_axes(p) for p in world_landmarks]
    root = _mid(flipped[23], flipped[24])
    center_shoulder = _mid(flipped[11], flipped[12])
    absolute: Dict[str, Vec3] = {
        "root": root,
        "spine": _mid(root, center_shoulder),
        "centerShoulder": center_shoulder,
    }
    for name, idx in MEDIAPIPE_INDEX.items():
        absolute[name] = flipped[idx]

    joints: Dict[str, Vec3] = {}
    confidences: Dict[str, float] = {}
    for name in CANONICAL_JOINTS:
        p = absolute[name]
        joints[name] = [p[0] - root[0], p[1] - root[1], p[2] - root[2]]
        sources = SYNTHESIZED_SOURCES.get(name, (MEDIAPIPE_INDEX.get(name, -1),))
        confidences[name] = min(_clamp01(visibility[i]) for i in sources)

    frame: Dict[str, Any] = {"t": float(t), "joints": joints, "confidences": confidences}

    if hands:
        if image_landmarks is None or len(image_landmarks) != MEDIAPIPE_POSE_LANDMARKS:
            raise ValueError("hands need the pose image_landmarks for nearest-wrist assignment")
        for h in hands:
            if len(h["world_landmarks"]) != MEDIAPIPE_HAND_LANDMARKS or len(h["image_landmarks"]) != MEDIAPIPE_HAND_LANDMARKS:
                raise ValueError(f"expected {MEDIAPIPE_HAND_LANDMARKS} hand landmarks")
        out_hands: Dict[str, List[Vec3]] = {}
        for side, idx in sorted(_assign_hands(hands, image_landmarks, image_aspect).items()):
            pts = [mediapipe_axes(p) for p in hands[idx]["world_landmarks"]]
            w, h0 = joints[side + "Wrist"], pts[0]
            out_hands[side] = [[w[0] + (p[0] - h0[0]), w[1] + (p[1] - h0[1]), w[2] + (p[2] - h0[2])] for p in pts]
        frame["hands"] = out_hands

    return frame


def bone_lengths(frame: Mapping[str, Any]) -> Dict[str, float]:
    """Length (m) of every `CANONICAL_BONES` bone present in a canonical frame, keyed by child joint."""
    joints = frame["joints"]
    out: Dict[str, float] = {}
    for child, parent in CANONICAL_BONES:
        c, p = joints.get(child), joints.get(parent)
        if c is None or p is None:
            continue
        out[child] = math.sqrt(sum((float(c[k]) - float(p[k])) ** 2 for k in range(3)))
    return out
