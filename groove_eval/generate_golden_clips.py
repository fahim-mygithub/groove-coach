"""Generate 20 synthetic 30-fps golden pose clips across 2 reference moves for Milestone 0."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, List, Tuple

Vec3 = Tuple[float, float, float]


def _rotate_x(pt: Vec3, deg: float) -> Vec3:
    """Rotate a 3D point around the X axis by `deg` degrees (simulating a tilted phone camera)."""
    rad = math.radians(deg)
    c, s = math.cos(rad), math.sin(rad)
    return (pt[0], pt[1] * c - pt[2] * s, pt[1] * s + pt[2] * c)


def _synthesize_skeleton_frame(
    t: float,
    knee_flex_deg: float,
    spine_jack_deg: float,
    trunk_lean_deg: float,
    left_foot_pitch_deg: float,
    right_foot_pitch_deg: float,
    hip_x_offset: float = 0.0,
    body_scale: float = 1.0,
    camera_tilt_deg: float = 0.0,
    mirror: bool = False,
    foot_confidence: float = 0.98,
) -> Dict[str, Any]:
    """Synthesize a realistic 3D skeleton (Apple Vision 17 joints + Core ML 4 foot keypoints)."""
    thigh_len = 0.42 * body_scale
    shin_len = 0.40 * body_scale
    lower_spine_len = 0.26 * body_scale
    upper_spine_len = 0.26 * body_scale
    foot_len = 0.22 * body_scale

    # Split knee flexion symmetrically between thigh forward pitch and shin backward pitch
    half_knee_rad = math.radians(max(0.0, knee_flex_deg) * 0.5)
    hip_y = (thigh_len + shin_len) * math.cos(half_knee_rad)
    knee_y = shin_len * math.cos(half_knee_rad)
    knee_z = -shin_len * math.sin(half_knee_rad)

    # Spine vectors: lower spine leans by trunk_lean_deg - spine_jack_deg/2,
    # upper spine bends by +spine_jack_deg relative to lower spine
    lower_rad = math.radians(trunk_lean_deg - 0.5 * spine_jack_deg)
    upper_rad = math.radians(trunk_lean_deg + 0.5 * spine_jack_deg)

    root: Vec3 = (hip_x_offset * body_scale, hip_y, 0.0)
    spine: Vec3 = (
        root[0],
        root[1] + lower_spine_len * math.cos(lower_rad),
        root[2] - lower_spine_len * math.sin(lower_rad),
    )
    center_shoulder: Vec3 = (
        spine[0],
        spine[1] + upper_spine_len * math.cos(upper_rad),
        spine[2] - upper_spine_len * math.sin(upper_rad),
    )

    hip_half_w = 0.11 * body_scale
    shoulder_half_w = 0.18 * body_scale

    l_pitch_rad = math.radians(left_foot_pitch_deg)
    r_pitch_rad = math.radians(right_foot_pitch_deg)

    joints_world: Dict[str, Vec3] = {
        "root": root,
        "spine": spine,
        "centerShoulder": center_shoulder,
        "leftHip": (root[0] - hip_half_w, hip_y, 0.0),
        "rightHip": (root[0] + hip_half_w, hip_y, 0.0),
        "leftKnee": (root[0] - hip_half_w, knee_y, knee_z),
        "rightKnee": (root[0] + hip_half_w, knee_y, knee_z),
        "leftAnkle": (root[0] - hip_half_w, 0.05 * body_scale, 0.0),
        "rightAnkle": (root[0] + hip_half_w, 0.05 * body_scale, 0.0),
        "leftShoulder": (center_shoulder[0] - shoulder_half_w, center_shoulder[1], center_shoulder[2]),
        "rightShoulder": (center_shoulder[0] + shoulder_half_w, center_shoulder[1], center_shoulder[2]),
        "leftHeel": (root[0] - hip_half_w, 0.0, 0.04 * body_scale),
        "leftFootIndex": (
            root[0] - hip_half_w,
            foot_len * math.sin(l_pitch_rad),
            0.04 * body_scale - foot_len * math.cos(l_pitch_rad),
        ),
        "rightHeel": (root[0] + hip_half_w, 0.0, 0.04 * body_scale),
        "rightFootIndex": (
            root[0] + hip_half_w,
            foot_len * math.sin(r_pitch_rad),
            0.04 * body_scale - foot_len * math.cos(r_pitch_rad),
        ),
    }

    if mirror:
        mirrored_world: Dict[str, Vec3] = {}
        for k, v in joints_world.items():
            mirrored_world[k] = (-v[0], v[1], v[2])
        swap_pairs = [
            ("leftHip", "rightHip"),
            ("leftKnee", "rightKnee"),
            ("leftAnkle", "rightAnkle"),
            ("leftShoulder", "rightShoulder"),
            ("leftHeel", "rightHeel"),
            ("leftFootIndex", "rightFootIndex"),
        ]
        for l_k, r_k in swap_pairs:
            mirrored_world[l_k], mirrored_world[r_k] = mirrored_world[r_k], mirrored_world[l_k]
        joints_world = mirrored_world

    # Apply camera tilt so raw coordinates are in camera space
    joints_cam = {
        k: [round(coord, 6) for coord in _rotate_x(pt, camera_tilt_deg)]
        for k, pt in joints_world.items()
    }

    confidences = {k: 0.98 for k in joints_cam}
    for fk in ("leftHeel", "leftFootIndex", "rightHeel", "rightFootIndex"):
        confidences[fk] = foot_confidence

    return {
        "t": round(t, 5),
        "joints": joints_cam,
        "confidences": confidences,
    }


def _build_clip(
    clip_id: str,
    move_tag: str,
    bpm: float,
    beat_times: List[float],
    description: str,
    expected_pass: bool,
    expected_failure_reason: str,
    timing_offset_ms: float = 0.0,
    second_half_offset_ms: Optional[float] = None,
    knee_amp_deg: float = 34.0,
    spine_amp_deg: float = 14.0,
    spine_lag_s: float = 0.066,
    foot_pitch_amp_deg: float = 0.0,
    camera_tilt_deg: float = 0.0,
    body_scale: float = 1.0,
    mirrored: bool = False,
    audio_latency_ms: float = 0.0,
    jerky_quantize: bool = False,
    low_foot_coverage: bool = False,
    wrong_move_mode: Optional[str] = None,
    fps: int = 30,
) -> Dict[str, Any]:
    beat_period = 60.0 / bpm
    duration = beat_times[-1] + beat_period
    num_frames = int(round(duration * fps))
    frames = []

    for idx in range(num_frames):
        t = idx / fps
        local_offset_s = timing_offset_ms / 1000.0
        if second_half_offset_ms is not None and t >= (beat_times[3] + 0.5 * beat_period):
            local_offset_s = second_half_offset_ms / 1000.0

        t_eff = t - local_offset_s - (audio_latency_ms / 1000.0)
        phase = 2.0 * math.pi * ((t_eff - beat_times[0]) / beat_period)
        spine_phase = 2.0 * math.pi * ((t_eff - spine_lag_s - beat_times[0]) / beat_period)

        if wrong_move_mode == "static":
            knee_flex = 6.0
            spine_jack = 2.0
            trunk_lean = 3.0
            l_foot = 0.0
            r_foot = 0.0
            hip_x = 0.0
        elif wrong_move_mode == "step_touch_anti_phase":
            # Anti-phase knees (standing straight on the beat) + big side-to-side hip sway
            knee_flex = 8.0 + 18.0 * (0.5 * (1.0 - math.cos(phase)))
            spine_jack = 1.0
            trunk_lean = 2.0
            l_foot = -15.0
            r_foot = -15.0
            hip_x = 0.38 * math.sin(0.5 * phase)
        else:
            wave = 0.5 * (1.0 + math.cos(phase))
            if jerky_quantize:
                # Square-wave-like snappy stops that inject high third-derivative jerk
                wave = 1.0 if wave > 0.5 else 0.0
            knee_flex = 8.0 + knee_amp_deg * wave
            spine_wave = 0.5 * (1.0 + math.cos(spine_phase))
            spine_jack = 4.0 + spine_amp_deg * spine_wave
            trunk_lean = 6.0 + 0.35 * spine_jack
            l_foot = foot_pitch_amp_deg * math.cos(phase)
            r_foot = -foot_pitch_amp_deg * math.cos(phase)
            hip_x = 0.0

        foot_conf = 0.20 if (low_foot_coverage and idx % 2 == 0) else 0.98
        frames.append(
            _synthesize_skeleton_frame(
                t=t,
                knee_flex_deg=knee_flex,
                spine_jack_deg=spine_jack,
                trunk_lean_deg=trunk_lean,
                left_foot_pitch_deg=l_foot,
                right_foot_pitch_deg=r_foot,
                hip_x_offset=hip_x,
                body_scale=body_scale,
                camera_tilt_deg=camera_tilt_deg,
                mirror=mirrored,
                foot_confidence=foot_conf,
            )
        )

    gravity_cam = _rotate_x((0.0, -1.0, 0.0), camera_tilt_deg)
    return {
        "clip_id": clip_id,
        "move_tag": move_tag,
        "bpm": bpm,
        "beat_times": beat_times,
        "description": description,
        "gravity_vector": [round(c, 6) for c in gravity_cam],
        "mirrored": mirrored,
        "audio_latency_ms": audio_latency_ms,
        "speed_pct": 100,
        "expected": {
            "passed": expected_pass,
            "reason": expected_failure_reason,
        },
        "frames": frames,
    }


def generate_golden_dataset() -> Dict[str, Any]:
    bounce_bpm = 110.0
    bounce_period = 60.0 / bounce_bpm
    bounce_beats = [round(0.5 + i * bounce_period, 5) for i in range(8)]

    jack_bpm = 118.0
    jack_period = 60.0 / jack_bpm
    jack_beats = [round(0.5 + i * jack_period, 5) for i in range(8)]

    references = {
        "down_bounce": _build_clip(
            clip_id="ref_down_bounce",
            move_tag="down_bounce",
            bpm=bounce_bpm,
            beat_times=bounce_beats,
            description="Golden reference for Tier 1 Down-Bounce at 110 BPM",
            expected_pass=True,
            expected_failure_reason="none",
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        "house_jack": _build_clip(
            clip_id="ref_house_jack",
            move_tag="house_jack",
            bpm=jack_bpm,
            beat_times=jack_beats,
            description="Golden reference for Tier 1/2 House Jack with heel-toe weight shift at 118 BPM",
            expected_pass=True,
            expected_failure_reason="none",
            knee_amp_deg=32.0,
            spine_amp_deg=22.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=24.0,
        ),
    }

    clips = [
        # --- 12 Down-Bounce Golden Clips ---
        _build_clip(
            "clip_01_bounce_clean_perfect",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Clean on-beat down-bounce (+8 ms)",
            True,
            "none",
            timing_offset_ms=8.0,
            knee_amp_deg=33.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_02_bounce_clean_tilted_phone_22deg",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Clean bounce recorded with phone tilted 22 deg on floor (tests CoreMotion gravity fix)",
            True,
            "none",
            timing_offset_ms=12.0,
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
            camera_tilt_deg=22.0,
        ),
        _build_clip(
            "clip_03_bounce_clean_mirrored_tall",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Clean mirrored take with 1.18x taller dancer proportions",
            True,
            "none",
            timing_offset_ms=-10.0,
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
            body_scale=1.18,
            mirrored=True,
        ),
        _build_clip(
            "clip_04_bounce_good_plus_85ms",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Slightly late take (+85 ms, within Good <= 120 ms gate)",
            True,
            "none",
            timing_offset_ms=85.0,
            knee_amp_deg=33.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_05_bounce_good_minus_75ms",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Slightly early take (-75 ms, within Good <= 120 ms gate)",
            True,
            "none",
            timing_offset_ms=-75.0,
            knee_amp_deg=33.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_06_bounce_audio_latency_calibrated",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Take with +140 ms raw delay compensated by 130 ms tap-test calibration",
            True,
            "none",
            timing_offset_ms=10.0,
            audio_latency_ms=130.0,
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_07_bounce_late_145ms",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Deliberately late take (+145 ms -> fails timing gate while keeping high shape score)",
            False,
            "timing_late",
            timing_offset_ms=145.0,
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_08_bounce_early_150ms",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Deliberately early take (-150 ms -> fails timing gate)",
            False,
            "timing_early",
            timing_offset_ms=-150.0,
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_09_bounce_stiff_locked_knees",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Stiff take with shallow locked knees (only 9 deg flex vs 34 deg ref) and zero spine lag",
            False,
            "stiff_groove",
            timing_offset_ms=5.0,
            knee_amp_deg=9.0,
            spine_amp_deg=2.0,
            spine_lag_s=0.0,
            foot_pitch_amp_deg=4.0,
        ),
        _build_clip(
            "clip_10_bounce_stiff_jerky_robot",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Robotic take with zero spine lag and high jerk stops",
            False,
            "stiff_groove",
            timing_offset_ms=0.0,
            knee_amp_deg=18.0,
            spine_amp_deg=2.0,
            spine_lag_s=0.0,
            foot_pitch_amp_deg=4.0,
            jerky_quantize=True,
        ),
        _build_clip(
            "clip_11_bounce_low_coverage_occluded_feet",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Feet out of frame on 50% of frames (fails coverage gate < 80%)",
            False,
            "low_coverage",
            timing_offset_ms=5.0,
            knee_amp_deg=34.0,
            spine_amp_deg=12.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=4.0,
            low_foot_coverage=True,
        ),
        _build_clip(
            "clip_12_bounce_wrong_move_static",
            "down_bounce",
            bounce_bpm,
            bounce_beats,
            "Standing still instead of bouncing (fails timing/shape/groove)",
            False,
            "wrong_move",
            wrong_move_mode="static",
        ),
        # --- 8 House Jack + Heel-Toe Golden Clips ---
        _build_clip(
            "clip_13_jack_clean_perfect",
            "house_jack",
            jack_bpm,
            jack_beats,
            "Clean house jack with spine ripple and heel-toe pitch (+10 ms)",
            True,
            "none",
            timing_offset_ms=10.0,
            knee_amp_deg=32.0,
            spine_amp_deg=22.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=24.0,
        ),
        _build_clip(
            "clip_14_jack_clean_tilted_phone_18deg",
            "house_jack",
            jack_bpm,
            jack_beats,
            "Clean house jack with -18 deg camera tilt (tests CoreMotion gravity fix on spine jack)",
            True,
            "none",
            timing_offset_ms=-8.0,
            knee_amp_deg=32.0,
            spine_amp_deg=22.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=24.0,
            camera_tilt_deg=-18.0,
        ),
        _build_clip(
            "clip_15_jack_good_plus_90ms",
            "house_jack",
            jack_bpm,
            jack_beats,
            "House jack +90 ms late (passes within Good <= 120 ms gate)",
            True,
            "none",
            timing_offset_ms=90.0,
            knee_amp_deg=31.0,
            spine_amp_deg=21.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=23.0,
        ),
        _build_clip(
            "clip_16_jack_late_160ms",
            "house_jack",
            jack_bpm,
            jack_beats,
            "Deliberately late house jack (+160 ms -> fails timing gate)",
            False,
            "timing_late",
            timing_offset_ms=160.0,
            knee_amp_deg=32.0,
            spine_amp_deg=22.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=24.0,
        ),
        _build_clip(
            "clip_17_jack_stiff_no_spine_ripple",
            "house_jack",
            jack_bpm,
            jack_beats,
            "Bouncing knees with rigid spine and shallow knees (no house jack ripple -> fails groove)",
            False,
            "stiff_groove",
            timing_offset_ms=5.0,
            knee_amp_deg=15.0,
            spine_amp_deg=0.5,
            spine_lag_s=0.0,
            foot_pitch_amp_deg=22.0,
        ),
        _build_clip(
            "clip_18_jack_missing_footwork_flat_feet",
            "house_jack",
            jack_bpm,
            jack_beats,
            "Good upper body jack, but completely wrong/inverted foot pitch (caught by Core ML foot keypoints)",
            False,
            "foot_shape_error",
            timing_offset_ms=5.0,
            knee_amp_deg=32.0,
            spine_amp_deg=22.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=-55.0,
        ),
        _build_clip(
            "clip_19_jack_wrong_move_step_touch",
            "house_jack",
            jack_bpm,
            jack_beats,
            "Performing lateral step-touch out of phase instead of house jack",
            False,
            "wrong_move",
            wrong_move_mode="step_touch_anti_phase",
        ),
        _build_clip(
            "clip_20_jack_rushed_second_half",
            "house_jack",
            jack_bpm,
            jack_beats,
            "On-beat for counts 1-4, then rushes counts 5-8 by -155 ms (50% Good+ < 80% gate)",
            False,
            "timing_early",
            timing_offset_ms=5.0,
            second_half_offset_ms=-155.0,
            knee_amp_deg=32.0,
            spine_amp_deg=22.0,
            spine_lag_s=0.066,
            foot_pitch_amp_deg=24.0,
        ),
    ]

    return {
        "references": references,
        "golden_clips": clips,
    }


def main() -> None:
    out_dir = Path(__file__).resolve().parent.parent / "fixtures"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "golden_clips.json"
    dataset = generate_golden_dataset()
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(dataset, f, indent=2)
    print(f"Generated {len(dataset['golden_clips'])} golden clips in {out_file}")


if __name__ == "__main__":
    main()
