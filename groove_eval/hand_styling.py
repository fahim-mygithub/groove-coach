"""Hand and finger styling analysis for Groove Coach (standalone module).

Works on 21-point hand landmarks in MediaPipe Hands order. Apple Vision's
VNHumanHandPoseObservation joints use the same ordering (the only naming difference is that
Vision calls the thumb's first knuckle ``MP`` where MediaPipe says ``MCP``, and the pinky "little"):

    idx   MediaPipe                Apple Vision
    0     WRIST                    wrist
    1-4   THUMB_CMC,MCP,IP,TIP     thumbCMC,thumbMP,thumbIP,thumbTip
    5-8   INDEX_MCP,PIP,DIP,TIP    indexMCP,indexPIP,indexDIP,indexTip
    9-12  MIDDLE_*                 middle*
    13-16 RING_*                   ring*
    17-20 PINKY_*                  little*

Coordinate convention (after mirroring a left hand to a right hand): x to the viewer's right,
y up, z toward the camera. A right hand held fingers-up with the palm to the camera therefore has
a palm normal of +z.

Implements:
1. Normalisation (translate to wrist, scale by wrist -> middle-MCP distance, mirror left to right).
2. Features: 5 finger curls, 4 adjacent fingertip gaps, thumb extension, palm orientation.
3. Shape classification (open, flat, fist, cupped, point, soft) with a confidence.
4. Learner vs reference comparison score (0-100).

The Swift mirror of this file is ios/GrooveCore/Sources/GrooveCore/HandStyling.swift.
"""

from __future__ import annotations

import math
from typing import Dict, List, Optional, Sequence, Tuple

Vec3 = Tuple[float, float, float]

HAND_LANDMARK_COUNT = 21
WRIST = 0
THUMB_TIP = 4
INDEX_MCP = 5
MIDDLE_MCP = 9
PINKY_MCP = 17
# (first joint, tip) landmark index per finger: thumb, index, middle, ring, pinky.
FINGER_CHAINS = ((1, 4), (5, 8), (9, 12), (13, 16), (17, 20))
FINGERTIPS = (4, 8, 12, 16, 20)

SHAPE_LABELS = ("open", "flat", "fist", "cupped", "point", "soft")

# Per shape: thumb, index, middle, ring, pinky curl, mean of the 3 finger-finger gaps, thumb extension.
SHAPE_PROTOTYPES: Dict[str, Tuple[float, ...]] = {
    "open": (0.0, 0.0, 0.0, 0.0, 0.0, 0.58, 0.60),
    "flat": (0.0, 0.0, 0.0, 0.0, 0.0, 0.32, 0.15),
    "fist": (0.6, 1.0, 1.0, 1.0, 1.0, 0.25, 0.75),
    "cupped": (0.25, 0.6, 0.6, 0.6, 0.6, 0.30, 0.60),
    "point": (0.6, 0.0, 1.0, 1.0, 1.0, 0.55, 0.75),
    "soft": (0.1, 0.15, 0.15, 0.15, 0.15, 0.38, 0.45),
}

DEFAULT_CURL_RANGE = 0.3  # 1 - straightness at which a finger counts as fully curled
DEFAULT_THUMB_EXTENSION_REF = 1.0  # thumb tip -> index MCP distance (in hand sizes) = fully extended
DEFAULT_ORIENTATION_THRESHOLD = 0.5  # palm normal z beyond +/- this = facing camera / away
DEFAULT_SHAPE_TOLERANCE = 0.4  # rms prototype distance at which a shape score reaches 0
DEFAULT_MIN_CONFIDENCE = 0.25  # below this the label is "unknown"
DEFAULT_COMPARE_WEIGHTS = (0.5, 0.2, 0.1, 0.2)  # curl, gap, thumb extension, orientation
DEFAULT_GAP_SCALE = 0.5  # mean gap difference (in hand sizes) that counts as fully different


def _sub(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _norm(a: Vec3) -> float:
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def _dist(a: Vec3, b: Vec3) -> float:
    return _norm(_sub(a, b))


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def normalize_hand(points: Sequence[Vec3], is_left: bool = False) -> Optional[List[Vec3]]:
    """Translate to the wrist, scale by wrist -> middle-MCP distance, mirror left hands to right.

    Returns None if there are not 21 points or the hand has no size.
    """
    if len(points) != HAND_LANDMARK_COUNT:
        return None
    wrist = points[WRIST]
    size = _dist(points[MIDDLE_MCP], wrist)
    if size < 1e-9:
        return None
    sign = -1.0 if is_left else 1.0
    out: List[Vec3] = []
    for p in points:
        d = _sub(p, wrist)
        out.append((sign * d[0] / size, d[1] / size, d[2] / size))
    return out


def finger_curl(hand: Sequence[Vec3], finger: int, curl_range: float = DEFAULT_CURL_RANGE) -> float:
    """Curl in [0, 1] for finger 0..4 (thumb, index, middle, ring, pinky) of a normalised hand.

    Straightness = chord(first joint, tip) / summed segment lengths: 1 when straight, lower when bent.
    """
    first, tip = FINGER_CHAINS[finger]
    path = 0.0
    for i in range(first, tip):
        path += _dist(hand[i + 1], hand[i])
    if path < 1e-9:
        return 0.0
    straightness = _dist(hand[tip], hand[first]) / path
    return _clamp((1.0 - straightness) / curl_range, 0.0, 1.0)


def palm_normal(hand: Sequence[Vec3]) -> Vec3:
    """Unit palm normal: (index MCP - wrist) x (pinky MCP - wrist) of a normalised (right) hand."""
    n = _cross(_sub(hand[INDEX_MCP], hand[WRIST]), _sub(hand[PINKY_MCP], hand[WRIST]))
    length = _norm(n)
    if length < 1e-9:
        return (0.0, 0.0, 0.0)
    return (n[0] / length, n[1] / length, n[2] / length)


def palm_orientation(normal: Vec3, threshold: float = DEFAULT_ORIENTATION_THRESHOLD) -> str:
    """'camera' (palm toward camera), 'away' or 'sideways'."""
    if normal[2] > threshold:
        return "camera"
    if normal[2] < -threshold:
        return "away"
    return "sideways"


def extract_hand_features(
    points: Sequence[Vec3],
    is_left: bool = False,
    curl_range: float = DEFAULT_CURL_RANGE,
    thumb_extension_ref: float = DEFAULT_THUMB_EXTENSION_REF,
    orientation_threshold: float = DEFAULT_ORIENTATION_THRESHOLD,
) -> Optional[Dict[str, object]]:
    """Features of one hand, or None if the landmarks are unusable."""
    hand = normalize_hand(points, is_left)
    if hand is None:
        return None
    curls = [finger_curl(hand, f, curl_range) for f in range(5)]
    gaps = [_dist(hand[FINGERTIPS[i]], hand[FINGERTIPS[i + 1]]) for i in range(4)]
    thumb_extension = _clamp(_dist(hand[THUMB_TIP], hand[INDEX_MCP]) / thumb_extension_ref, 0.0, 1.0)
    normal = palm_normal(hand)
    return {
        "curls": curls,
        "gaps": gaps,
        "thumb_extension": thumb_extension,
        "palm_normal": normal,
        "palm_orientation": palm_orientation(normal, orientation_threshold),
    }


def classify_hand_shape(
    features: Dict[str, object],
    tolerance: float = DEFAULT_SHAPE_TOLERANCE,
    min_confidence: float = DEFAULT_MIN_CONFIDENCE,
) -> Dict[str, object]:
    """Best-matching dance hand shape: {'label', 'confidence', 'scores'}.

    Each shape scores 1 - rms(feature - prototype) / tolerance, clamped to [0, 1]; the confidence
    is the best score and the label is 'unknown' when it falls below min_confidence.
    """
    curls: List[float] = features["curls"]  # type: ignore[assignment]
    gaps: List[float] = features["gaps"]  # type: ignore[assignment]
    vec = list(curls) + [(gaps[1] + gaps[2] + gaps[3]) / 3.0, features["thumb_extension"]]
    scores: Dict[str, float] = {}
    for label in SHAPE_LABELS:
        proto = SHAPE_PROTOTYPES[label]
        sq = 0.0
        for a, b in zip(vec, proto):
            sq += (a - b) * (a - b)  # type: ignore[operator]
        rms = math.sqrt(sq / len(proto))
        scores[label] = _clamp(1.0 - rms / tolerance, 0.0, 1.0)
    best_label = SHAPE_LABELS[0]
    for label in SHAPE_LABELS:
        if scores[label] > scores[best_label]:
            best_label = label
    confidence = scores[best_label]
    return {
        "label": best_label if confidence >= min_confidence else "unknown",
        "confidence": confidence,
        "scores": scores,
    }


def compare_hand_features(
    learner: Dict[str, object],
    reference: Dict[str, object],
    weights: Tuple[float, float, float, float] = DEFAULT_COMPARE_WEIGHTS,
    gap_scale: float = DEFAULT_GAP_SCALE,
) -> float:
    """Similarity 0-100 between learner and reference hand features (100 = identical shape).

    Weighted sum of mean curl difference, mean gap difference / gap_scale, thumb-extension
    difference and palm-normal angle / pi.
    """
    lc: List[float] = learner["curls"]  # type: ignore[assignment]
    rc: List[float] = reference["curls"]  # type: ignore[assignment]
    lg: List[float] = learner["gaps"]  # type: ignore[assignment]
    rg: List[float] = reference["gaps"]  # type: ignore[assignment]
    curl_d = sum(abs(a - b) for a, b in zip(lc, rc)) / 5.0
    gap_d = _clamp(sum(abs(a - b) for a, b in zip(lg, rg)) / 4.0 / gap_scale, 0.0, 1.0)
    thumb_d = abs(learner["thumb_extension"] - reference["thumb_extension"])  # type: ignore[operator]
    ln: Vec3 = learner["palm_normal"]  # type: ignore[assignment]
    rn: Vec3 = reference["palm_normal"]  # type: ignore[assignment]
    cos = _clamp(ln[0] * rn[0] + ln[1] * rn[1] + ln[2] * rn[2], -1.0, 1.0)
    orient_d = math.acos(cos) / math.pi
    total = (
        weights[0] * curl_d
        + weights[1] * gap_d
        + weights[2] * _clamp(thumb_d, 0.0, 1.0)
        + weights[3] * orient_d
    )
    return 100.0 * _clamp(1.0 - total, 0.0, 1.0)
