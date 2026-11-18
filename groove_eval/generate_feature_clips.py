"""Generate synthetic feature clips exercising hit timing, joint verdicts and hand styling.

The 20 golden clips are continuous grooves without hand landmarks, so the settle-after-move hit component is
`not_applicable` and hand styling is `skipped` on all of them. This small set (one `arm_hits` reference + 4 attempts)
adds arm hits that land on the beat and 21-point hand landmarks so Python/Swift parity covers those paths too.

Body: the down-bounce skeleton from `generate_golden_clips`. Arms: elbows/wrists snap between "down" and "out" poses,
arriving on each beat (+ hit offset) and holding until the next move. Hands: MediaPipe-order landmarks (same shapes as
tests/test_hand_styling.py) attached to the wrists, under `frame["hands"] = {"left": [...], "right": [...]}`.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from groove_eval.generate_golden_clips import _build_clip

Vec3 = Tuple[float, float, float]

HAND_SHAPES: Dict[str, Tuple[Vec3, ...]] = {
    "open": (
        (0.0, 0.0, 0.0),
        (0.2, 0.2, 0.0),
        (0.4298, 0.3928, 0.0),
        (0.6596, 0.5857, 0.0),
        (0.8511, 0.7464, 0.0),
        (0.3, 0.95, 0.0),
        (0.525, 1.3397, 0.0),
        (0.65, 1.5562, 0.0),
        (0.75, 1.7294, 0.0),
        (0.05, 1.0, 0.0),
        (0.1368, 1.4924, 0.0),
        (0.1854, 1.7682, 0.0),
        (0.2236, 1.9848, 0.0),
        (-0.2, 0.93, 0.0),
        (-0.2799, 1.383, 0.0),
        (-0.325, 1.6391, 0.0),
        (-0.3598, 1.836, 0.0),
        (-0.4, 0.8, 0.0),
        (-0.58, 1.1118, 0.0),
        (-0.68, 1.285, 0.0),
        (-0.765, 1.4322, 0.0),
    ),
    "flat": (
        (0.0, 0.0, 0.0),
        (0.2, 0.2, 0.0),
        (0.2521, 0.4954, 0.0),
        (0.3042, 0.7909, 0.0),
        (0.3476, 1.0371, 0.0),
        (0.3, 0.95, 0.0),
        (0.3, 1.4, 0.0),
        (0.3, 1.65, 0.0),
        (0.3, 1.85, 0.0),
        (0.05, 1.0, 0.0),
        (0.05, 1.5, 0.0),
        (0.05, 1.78, 0.0),
        (0.05, 2.0, 0.0),
        (-0.2, 0.93, 0.0),
        (-0.2, 1.39, 0.0),
        (-0.2, 1.65, 0.0),
        (-0.2, 1.85, 0.0),
        (-0.4, 0.8, 0.0),
        (-0.4, 1.16, 0.0),
        (-0.4, 1.36, 0.0),
        (-0.4, 1.53, 0.0),
    ),
    "fist": (
        (0.0, 0.0, 0.0),
        (0.2, 0.2, 0.0),
        (0.1036, 0.4649, -0.1026),
        (0.0523, 0.6059, -0.3624),
        (0.0815, 0.5255, -0.5973),
        (0.3, 0.95, 0.0),
        (0.3, 0.95, -0.45),
        (0.3, 0.7038, -0.4066),
        (0.3, 0.6691, -0.2096),
        (0.05, 1.0, 0.0),
        (0.05, 1.0, -0.5),
        (0.05, 0.7243, -0.4514),
        (0.05, 0.6861, -0.2347),
        (-0.2, 0.93, 0.0),
        (-0.2, 0.93, -0.46),
        (-0.2, 0.6739, -0.4149),
        (-0.2, 0.6392, -0.2179),
        (-0.4, 0.8, 0.0),
        (-0.4, 0.8, -0.36),
        (-0.4, 0.603, -0.3253),
        (-0.4, 0.5735, -0.1579),
    ),
}

BPM = 110.0
PERIOD = 60.0 / BPM
BEATS = [round(0.5 + i * PERIOD, 5) for i in range(8)]
MOVE_S = 0.18
HAND_SIZE_M = 0.09


def _smoothstep(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def _arm_phase(t: float, hit_offset_s: float, arms_move: bool) -> float:
    """0 = arms down, 1 = arms out; arrives at the target pose on each beat (+ offset) and holds."""
    if not arms_move:
        return 0.0
    pose = 0.0
    for k, b in enumerate(BEATS):
        target = 1.0 if k % 2 == 0 else 0.0
        arrive = b + hit_offset_s
        start = arrive - MOVE_S
        if t >= arrive:
            pose = target
        elif t > start:
            return pose + (target - pose) * _smoothstep((t - start) / MOVE_S)
        else:
            return pose
    return pose


def _hand_points(wrist: Sequence[float], shape: str, is_left: bool, mirror: bool) -> List[List[float]]:
    sign = -1.0 if is_left else 1.0
    if mirror:
        sign = -sign
    return [
        [round(wrist[0] + sign * HAND_SIZE_M * p[0], 5), round(wrist[1] + HAND_SIZE_M * p[1], 5), round(wrist[2] + HAND_SIZE_M * p[2], 5)]
        for p in HAND_SHAPES[shape]
    ]


def _add_arms_and_hands(
    clip: Dict[str, Any],
    hit_offset_ms: float,
    arms_move: bool,
    hand_shape: Optional[str],
) -> Dict[str, Any]:
    mirror = bool(clip.get("mirrored", False))
    for frame in clip["frames"]:
        joints = frame["joints"]
        center = joints["centerShoulder"]
        phase = _arm_phase(float(frame["t"]), hit_offset_ms / 1000.0, arms_move)
        hands: Dict[str, List[List[float]]] = {}
        for side in ("left", "right"):
            shoulder = joints[side + "Shoulder"]
            out = 1.0 if shoulder[0] >= center[0] else -1.0
            # down: hanging by the hip; out: horizontal, slightly raised
            wrist = (
                shoulder[0] + out * (0.08 + 0.47 * phase),
                shoulder[1] - 0.52 + 0.62 * phase,
                shoulder[2] + 0.05,
            )
            elbow = (
                shoulder[0] + out * (0.05 + 0.24 * phase),
                shoulder[1] - 0.27 + 0.30 * phase,
                shoulder[2] + 0.02,
            )
            joints[side + "Elbow"] = [round(c, 6) for c in elbow]
            joints[side + "Wrist"] = [round(c, 6) for c in wrist]
            frame["confidences"][side + "Elbow"] = 0.98
            frame["confidences"][side + "Wrist"] = 0.98
            if hand_shape is not None:
                # In a mirrored clip the physical left hand appears on the image's right: geometry as `side`,
                # mirrored once more by the camera.
                hands[side] = _hand_points(wrist, hand_shape, is_left=(side == "left"), mirror=mirror)
        if hand_shape is not None:
            frame["hands"] = hands
    return clip


def _clip(
    clip_id: str,
    description: str,
    hit_offset_ms: float,
    hand_shape: Optional[str],
    hits_status: str,
    hands_status: str,
    body_offset_ms: float = 0.0,
    arms_move: bool = True,
    mirrored: bool = False,
) -> Dict[str, Any]:
    clip = _build_clip(
        clip_id=clip_id,
        move_tag="arm_hits",
        bpm=BPM,
        beat_times=BEATS,
        description=description,
        expected_pass=True,
        expected_failure_reason="none",
        timing_offset_ms=body_offset_ms,
        knee_amp_deg=34.0,
        spine_amp_deg=12.0,
        spine_lag_s=0.066,
        foot_pitch_amp_deg=4.0,
        mirrored=mirrored,
    )
    clip["expected"]["hits_status"] = hits_status
    clip["expected"]["hands_status"] = hands_status
    return _add_arms_and_hands(clip, hit_offset_ms, arms_move, hand_shape)


def generate_feature_dataset() -> Dict[str, Any]:
    reference = _clip(
        "ref_arm_hits", "Reference: down-bounce with arm hits landing on every beat, open hands", 0.0, "open",
        "available", "available",
    )
    clips = [
        _clip("feat_01_hits_clean_open_hands", "Hits on the beat, open hands", 10.0, "open",
              "available", "available", body_offset_ms=8.0),
        _clip("feat_02_hits_late_fist_hands", "Hits ~110 ms late, fists instead of open hands", 110.0, "fist",
              "available", "available", body_offset_ms=5.0),
        _clip("feat_03_no_hits_no_hands", "Bounce is clean but the arms never hit; no hand landmarks", 0.0, None,
              "available", "skipped", body_offset_ms=5.0, arms_move=False),
        _clip("feat_04_mirrored_hits_flat_hands", "Mirrored selfie take, hits on the beat, flat hands", -20.0, "flat",
              "available", "available", body_offset_ms=-6.0, mirrored=True),
    ]
    return {"references": {"arm_hits": reference}, "golden_clips": clips}


def main() -> None:
    out_file = Path(__file__).resolve().parent.parent / "fixtures" / "feature_clips.json"
    dataset = generate_feature_dataset()
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(dataset, f, separators=(",", ":"))
        f.write("\n")
    print(f"Generated {len(dataset['golden_clips'])} feature clips in {out_file}")


if __name__ == "__main__":
    main()
