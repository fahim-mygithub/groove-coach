"""Deterministic on-device scoring engine reference implementation for Groove Coach (M0).

Implements:
1. CoreMotion gravity-vector tilt correction (camera 3D -> gravity-aligned world 3D).
2. Unified Apple Vision 3D (17 joints including root, spine, centerShoulder) +
   Core ML foot keypoints (left/right heel and foot_index) feature extraction.
3. Turnaround-phase timing (zero-velocity dip/impact extremum with sub-frame parabolic interpolation).
4. Phase-shifted Shape scoring (decoupled from timing offset, mirror-aware).
5. Groove & Stiffness scoring (knee flex dynamic range, spine-to-knee phase lag, dimensionless squared jerk).
6. Coverage scoring & strict JSON schema validation.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

Vec3 = Tuple[float, float, float]

REQUIRED_BODY_JOINTS = (
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
    "rightShoulder",
)

REQUIRED_FOOT_JOINTS = (
    "leftHeel",
    "leftFootIndex",
    "rightHeel",
    "rightFootIndex",
)


def load_config(config_path: Optional[Path] = None) -> Dict[str, Any]:
    if config_path is None:
        config_path = Path(__file__).resolve().parent.parent / "config" / "groove_config.json"
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def _norm(v: Vec3) -> float:
    return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])


def _normalize(v: Vec3) -> Vec3:
    n = _norm(v)
    if n < 1e-9:
        return (0.0, 0.0, 0.0)
    return (v[0] / n, v[1] / n, v[2] / n)


def _sub(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _dot(a: Vec3, b: Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _angle_between_deg(u: Vec3, v: Vec3) -> float:
    un = _normalize(u)
    vn = _normalize(v)
    cos_val = max(-1.0, min(1.0, _dot(un, vn)))
    return math.degrees(math.acos(cos_val))


def apply_gravity_correction(point: Vec3, gravity_vector: Vec3) -> Vec3:
    """Rotate a camera-space 3D point so the measured gravity vector aligns with (0, -1, 0).

    Uses Rodrigues' rotation formula to map `g_unit` -> `target_down = (0, -1, 0)`.
    """
    g = _normalize(gravity_vector)
    target = (0.0, -1.0, 0.0)
    cos_theta = max(-1.0, min(1.0, _dot(g, target)))
    if cos_theta > 0.999999:
        return point
    if cos_theta < -0.999999:
        return (point[0], -point[1], -point[2])

    axis = _normalize(_cross(g, target))
    sin_theta = math.sqrt(max(0.0, 1.0 - cos_theta * cos_theta))
    k_dot_p = _dot(axis, point)
    k_cross_p = _cross(axis, point)

    return (
        point[0] * cos_theta + k_cross_p[0] * sin_theta + axis[0] * k_dot_p * (1.0 - cos_theta),
        point[1] * cos_theta + k_cross_p[1] * sin_theta + axis[1] * k_dot_p * (1.0 - cos_theta),
        point[2] * cos_theta + k_cross_p[2] * sin_theta + axis[2] * k_dot_p * (1.0 - cos_theta),
    )


def extract_frame_features(
    frame: Dict[str, Any],
    gravity_vector: Vec3,
    mirror: bool = False,
) -> Dict[str, float]:
    """Compute gravity-aligned, body-normalized joint angles and trajectories for a single frame."""
    raw_joints = frame["joints"]
    world_joints: Dict[str, Vec3] = {}
    for name, pt in raw_joints.items():
        if pt is None or len(pt) < 3:
            continue
        p = apply_gravity_correction((float(pt[0]), float(pt[1]), float(pt[2])), gravity_vector)
        if mirror:
            p = (-p[0], p[1], p[2])
        world_joints[name] = p

    if mirror:
        swap_pairs = [
            ("leftHip", "rightHip"),
            ("leftKnee", "rightKnee"),
            ("leftAnkle", "rightAnkle"),
            ("leftShoulder", "rightShoulder"),
            ("leftHeel", "rightHeel"),
            ("leftFootIndex", "rightFootIndex"),
        ]
        for l_name, r_name in swap_pairs:
            if l_name in world_joints and r_name in world_joints:
                world_joints[l_name], world_joints[r_name] = (
                    world_joints[r_name],
                    world_joints[l_name],
                )

    # Leg vectors: hip -> knee and knee -> ankle (0 deg = straight leg, >0 = flexed knee)
    l_thigh = _sub(world_joints["leftKnee"], world_joints["leftHip"])
    l_shin = _sub(world_joints["leftAnkle"], world_joints["leftKnee"])
    r_thigh = _sub(world_joints["rightKnee"], world_joints["rightHip"])
    r_shin = _sub(world_joints["rightAnkle"], world_joints["rightKnee"])

    left_knee_flex = _angle_between_deg(l_thigh, l_shin)
    right_knee_flex = _angle_between_deg(r_thigh, r_shin)

    # Spine jack angle: lower spine (root -> spine) vs upper spine (spine -> centerShoulder)
    lower_spine = _sub(world_joints["spine"], world_joints["root"])
    upper_spine = _sub(world_joints["centerShoulder"], world_joints["spine"])
    spine_jack_angle = _angle_between_deg(lower_spine, upper_spine)

    # Trunk forward/backward sagittal pitch relative to vertical (0, 1, 0)
    trunk_vec = _sub(world_joints["centerShoulder"], world_joints["root"])
    trunk_lean_deg = _angle_between_deg(trunk_vec, (0.0, 1.0, 0.0))

    # Foot pitch angles: ONLY computed when real foot keypoints exist (never faked from ankles)
    feet_present = all(k in world_joints for k in REQUIRED_FOOT_JOINTS)
    if feet_present:
        l_foot_vec = _normalize(_sub(world_joints["leftFootIndex"], world_joints["leftHeel"]))
        r_foot_vec = _normalize(_sub(world_joints["rightFootIndex"], world_joints["rightHeel"]))
        left_foot_pitch_deg = math.degrees(math.asin(max(-1.0, min(1.0, l_foot_vec[1]))))
        right_foot_pitch_deg = math.degrees(math.asin(max(-1.0, min(1.0, r_foot_vec[1]))))
        base_y = 0.5 * (world_joints["leftHeel"][1] + world_joints["rightHeel"][1])
    else:
        left_foot_pitch_deg = 0.0
        right_foot_pitch_deg = 0.0
        base_y = 0.5 * (world_joints["leftAnkle"][1] + world_joints["rightAnkle"][1]) - 0.05

    # Body-proportion normalization scale (average leg bone length: thigh + shin)
    leg_scale = 0.5 * ((_norm(l_thigh) + _norm(l_shin)) + (_norm(r_thigh) + _norm(r_shin)))
    leg_scale = max(leg_scale, 0.4)

    hip_height_norm = (world_joints["root"][1] - base_y) / leg_scale
    shoulder_height_norm = (world_joints["centerShoulder"][1] - world_joints["root"][1]) / leg_scale
    hip_x_norm = world_joints["root"][0] / leg_scale

    return {
        "t": float(frame["t"]),
        "left_knee_flex": left_knee_flex,
        "right_knee_flex": right_knee_flex,
        "mean_knee_flex": 0.5 * (left_knee_flex + right_knee_flex),
        "spine_jack_angle": spine_jack_angle,
        "trunk_lean_deg": trunk_lean_deg,
        "left_foot_pitch_deg": left_foot_pitch_deg,
        "right_foot_pitch_deg": right_foot_pitch_deg,
        "hip_height_norm": hip_height_norm,
        "shoulder_height_norm": shoulder_height_norm,
        "hip_x_norm": hip_x_norm,
    }


def _parabolic_peak_time(t0: float, y0: float, t1: float, y1: float, t2: float, y2: float) -> float:
    """Sub-frame quadratic interpolation around discrete extremum at index 1."""
    denom = 2.0 * (y0 - 2.0 * y1 + y2)
    if abs(denom) < 1e-9:
        return t1
    dt = 0.5 * (t2 - t0)
    offset = ((y0 - y2) / denom) * dt
    offset = max(-dt, min(dt, offset))
    return t1 + offset


def detect_turnaround_times(
    features: List[Dict[str, float]],
    beat_times: List[float],
    beat_period_s: float,
    search_window_beats: float = 0.45,
) -> List[Optional[float]]:
    """Detect kinematic turnaround timestamps (bottom of bounce dip / peak knee flexion) per beat."""
    half_win = search_window_beats * beat_period_s
    turnarounds: List[Optional[float]] = []

    for b_time in beat_times:
        indices = [
            i for i, f in enumerate(features) if (b_time - half_win) <= f["t"] <= (b_time + half_win)
        ]
        if len(indices) < 3:
            turnarounds.append(None)
            continue

        signal = [
            features[i]["mean_knee_flex"] - 40.0 * features[i]["hip_height_norm"] for i in indices
        ]
        val_range = max(signal) - min(signal)
        if val_range < 3.0:
            turnarounds.append(None)
            continue

        best_local_idx = max(range(len(indices)), key=lambda k: signal[k])
        global_idx = indices[best_local_idx]
        if 0 < global_idx < len(features) - 1:
            t_prev = features[global_idx - 1]["t"]
            t_curr = features[global_idx]["t"]
            t_next = features[global_idx + 1]["t"]
            y_prev = features[global_idx - 1]["mean_knee_flex"] - 40.0 * features[global_idx - 1]["hip_height_norm"]
            y_curr = features[global_idx]["mean_knee_flex"] - 40.0 * features[global_idx]["hip_height_norm"]
            y_next = features[global_idx + 1]["mean_knee_flex"] - 40.0 * features[global_idx + 1]["hip_height_norm"]
            t_peak = _parabolic_peak_time(t_prev, y_prev, t_curr, y_curr, t_next, y_next)
        else:
            t_peak = features[global_idx]["t"]

        turnarounds.append(t_peak)

    return turnarounds


def detect_velocity_peak_times(
    features: List[Dict[str, float]],
    beat_times: List[float],
    beat_period_s: float,
    search_window_beats: float = 0.45,
) -> List[Optional[float]]:
    """Helper demonstrating why velocity-peak timing is wrong for bounces (lands mid-way between beats)."""
    half_win = search_window_beats * beat_period_s
    vel_times: List[Optional[float]] = []
    velocities = [0.0] * len(features)
    for i in range(1, len(features) - 1):
        dt = features[i + 1]["t"] - features[i - 1]["t"]
        if dt > 1e-6:
            velocities[i] = abs(features[i + 1]["hip_height_norm"] - features[i - 1]["hip_height_norm"]) / dt

    for b_time in beat_times:
        indices = [
            i for i, f in enumerate(features) if (b_time - half_win) <= f["t"] <= (b_time + half_win)
        ]
        if not indices:
            vel_times.append(None)
            continue
        best_i = max(indices, key=lambda idx: velocities[idx])
        vel_times.append(features[best_i]["t"])
    return vel_times


def _interpolate_feature_at(features: List[Dict[str, float]], t_query: float, key: str) -> float:
    if t_query <= features[0]["t"]:
        return features[0][key]
    if t_query >= features[-1]["t"]:
        return features[-1][key]
    for i in range(len(features) - 1):
        t0, t1 = features[i]["t"], features[i + 1]["t"]
        if t0 <= t_query <= t1:
            alpha = (t_query - t0) / max(1e-9, t1 - t0)
            return (1.0 - alpha) * features[i][key] + alpha * features[i + 1][key]
    return features[-1][key]


def score_coverage(frames: List[Dict[str, Any]], min_confidence: float) -> float:
    if not frames:
        return 0.0
    valid_count = 0
    required = REQUIRED_BODY_JOINTS + REQUIRED_FOOT_JOINTS
    for frame in frames:
        joints = frame.get("joints", {})
        conf_map = frame.get("confidences", {})
        if all(
            (j in joints and joints[j] is not None and len(joints[j]) >= 3)
            and float(conf_map.get(j, 0.0)) >= min_confidence
            for j in required
        ):
            valid_count += 1
    return valid_count / len(frames)


def score_foot_coverage(frames: List[Dict[str, Any]], min_confidence: float) -> float:
    if not frames:
        return 0.0
    valid_count = 0
    for frame in frames:
        joints = frame.get("joints", {})
        conf_map = frame.get("confidences", {})
        if all(
            (j in joints and joints[j] is not None and len(joints[j]) >= 3)
            and float(conf_map.get(j, 0.0)) >= min_confidence
            for j in REQUIRED_FOOT_JOINTS
        ):
            valid_count += 1
    return valid_count / len(frames)


def score_timing(
    user_features: List[Dict[str, float]],
    ref_features: List[Dict[str, float]],
    beat_times: List[float],
    bpm: float,
    audio_latency_ms: float,
    timing_cfg: Dict[str, float],
) -> Dict[str, Any]:
    beat_period_s = 60.0 / bpm
    search_win = float(timing_cfg.get("search_window_beats", 0.45))
    perfect_ms = float(timing_cfg.get("perfect_max_ms", 60.0))
    good_ms = float(timing_cfg.get("good_max_ms", 120.0))

    ref_turnarounds = detect_turnaround_times(ref_features, beat_times, beat_period_s, search_win)
    user_turnarounds = detect_turnaround_times(user_features, beat_times, beat_period_s, search_win)

    per_beat = []
    valid_offsets_ms: List[float] = []
    good_or_better = 0

    for idx, b_time in enumerate(beat_times):
        count_num = idx + 1
        t_ref = ref_turnarounds[idx] if ref_turnarounds[idx] is not None else b_time
        t_usr = user_turnarounds[idx]

        if t_usr is None:
            per_beat.append(
                {
                    "count_number": count_num,
                    "offset_ms": 999.0,
                    "judgment": "Miss",
                }
            )
            continue

        offset_ms = ((t_usr - (audio_latency_ms / 1000.0)) - t_ref) * 1000.0
        abs_ms = abs(offset_ms)
        valid_offsets_ms.append(offset_ms)

        if abs_ms <= perfect_ms:
            judgment = "Perfect"
            good_or_better += 1
        elif abs_ms <= good_ms:
            judgment = "Good"
            good_or_better += 1
        elif offset_ms < 0:
            judgment = "Early"
        else:
            judgment = "Late"

        per_beat.append(
            {
                "count_number": count_num,
                "offset_ms": round(offset_ms, 2),
                "judgment": judgment,
            }
        )

    mean_offset_ms = (
        sum(valid_offsets_ms) / len(valid_offsets_ms) if valid_offsets_ms else 999.0
    )
    good_or_better_ratio = good_or_better / max(1, len(beat_times))

    worst_beat = max(per_beat, key=lambda b: abs(b["offset_ms"]))
    return {
        "per_beat": per_beat,
        "mean_offset_ms": round(mean_offset_ms, 2),
        "good_or_better_ratio": round(good_or_better_ratio, 3),
        "worst_beat": worst_beat,
    }


def score_shape(
    user_features: List[Dict[str, float]],
    ref_features: List[Dict[str, float]],
    beat_times: List[float],
    per_beat_timing: List[Dict[str, Any]],
    audio_latency_ms: float,
    shape_cfg: Dict[str, float],
) -> Dict[str, Any]:
    """Phase-shifted Shape score: shifts user curve by measured turnaround offset so timing isn't double-penalized."""
    max_err = float(shape_cfg.get("max_angle_error_deg", 45.0))
    foot_weight = float(shape_cfg.get("foot_pitch_weight", 0.30))

    joint_keys = [
        ("knees", "mean_knee_flex", 0.30),
        ("spine", "spine_jack_angle", 0.25),
        ("hips", "trunk_lean_deg", 0.15),
        ("left_foot", "left_foot_pitch_deg", 0.5 * foot_weight),
        ("right_foot", "right_foot_pitch_deg", 0.5 * foot_weight),
    ]

    joint_errors: Dict[str, List[float]] = {name: [] for name, _, _ in joint_keys}
    lateral_errors: List[float] = []

    for idx, b_time in enumerate(beat_times):
        beat_info = per_beat_timing[idx]
        offset_s = (
            (beat_info["offset_ms"] / 1000.0) if beat_info["judgment"] != "Miss" else 0.0
        ) + (audio_latency_ms / 1000.0)

        for sample_delta in (-0.12, 0.0, 0.12):
            t_ref = b_time + sample_delta
            t_usr = t_ref + offset_s
            for joint_name, feat_key, _ in joint_keys:
                v_ref = _interpolate_feature_at(ref_features, t_ref, feat_key)
                v_usr = _interpolate_feature_at(user_features, t_usr, feat_key)
                joint_errors[joint_name].append(abs(v_usr - v_ref))

            x_ref = _interpolate_feature_at(ref_features, t_ref, "hip_x_norm")
            x_usr = _interpolate_feature_at(user_features, t_usr, "hip_x_norm")
            lateral_errors.append(abs(x_usr - x_ref) * 90.0)

    mean_joint_err = {
        name: sum(vals) / max(1, len(vals)) for name, vals in joint_errors.items()
    }
    mean_joint_err["hips"] += sum(lateral_errors) / max(1, len(lateral_errors))

    weighted_score = 0.0
    for joint_name, _, weight in joint_keys:
        err = mean_joint_err[joint_name]
        component = max(0.0, 100.0 * (1.0 - (err / max_err)))
        weighted_score += weight * component

    worst_joints = sorted(
        [
            {"joint": k, "mean_angle_error_deg": round(v, 2)}
            for k, v in mean_joint_err.items()
        ],
        key=lambda item: item["mean_angle_error_deg"],
        reverse=True,
    )[:3]

    # Single-joint failure ceiling: if any active joint group (e.g. feet on a footwork move)
    # exceeds max_single_joint_error_deg, cap shape_score so upper body alone cannot mask missing footwork.
    max_single_err = float(shape_cfg.get("max_single_joint_error_deg", 24.0))
    pass_min = float(shape_cfg.get("pass_min_score", 70.0))
    worst_err = worst_joints[0]["mean_angle_error_deg"] if worst_joints else 0.0
    if worst_err > max_single_err:
        excess_ratio = (worst_err - max_single_err) / max(1.0, max_err - max_single_err)
        cap_score = max(0.0, (pass_min - 2.0) * (1.0 - 0.6 * excess_ratio))
        weighted_score = min(weighted_score, cap_score)

    return {
        "shape_score": round(weighted_score, 2),
        "worst_joints": worst_joints,
        "joint_errors": {k: round(v, 2) for k, v in mean_joint_err.items()},
    }


def _estimate_spine_knee_lag_ms(features: List[Dict[str, float]]) -> float:
    """Estimate lag (ms) by which the spine/chest ripple follows the knee flexion wave."""
    if len(features) < 10:
        return 0.0
    dt = features[1]["t"] - features[0]["t"]
    if dt <= 0:
        return 0.0

    knee_sig = [f["mean_knee_flex"] for f in features]
    spine_sig = [f["spine_jack_angle"] for f in features]
    k_mean = sum(knee_sig) / len(knee_sig)
    s_mean = sum(spine_sig) / len(spine_sig)
    knee_centered = [x - k_mean for x in knee_sig]
    spine_centered = [x - s_mean for x in spine_sig]

    if max(knee_centered) - min(knee_centered) < 2.0 or max(spine_centered) - min(spine_centered) < 1.5:
        return 0.0

    max_shift = min(6, len(features) // 4)
    best_shift = 0
    best_corr = -1e18
    for shift in range(0, max_shift + 1):
        corr = sum(
            knee_centered[i] * spine_centered[i + shift]
            for i in range(len(features) - shift)
        )
        if corr > best_corr:
            best_corr = corr
            best_shift = shift

    return round(best_shift * dt * 1000.0, 2)


def _compute_dimensionless_jerk(features: List[Dict[str, float]]) -> float:
    """Compute dimensionless squared jerk on vertical hip bounce trajectory."""
    if len(features) < 5:
        return 0.0
    dt = features[1]["t"] - features[0]["t"]
    y = [f["hip_height_norm"] for f in features]
    amp = max(y) - min(y)
    if amp < 0.015 or dt <= 0:
        return 1e9

    jerk_sq_sum = 0.0
    for i in range(1, len(y) - 2):
        j = (y[i + 2] - 3.0 * y[i + 1] + 3.0 * y[i] - y[i - 1]) / (dt**3)
        jerk_sq_sum += (j * j) * dt

    duration = min(1.0, features[-1]["t"] - features[0]["t"])
    dsj = (jerk_sq_sum * (duration**5)) / (amp * amp)
    return round(dsj / 1000.0, 2)


def score_groove(
    user_features: List[Dict[str, float]],
    ref_features: List[Dict[str, float]],
    groove_cfg: Dict[str, float],
) -> Dict[str, Any]:
    user_knee_vals = [f["mean_knee_flex"] for f in user_features]
    ref_knee_vals = [f["mean_knee_flex"] for f in ref_features]
    user_knee_range = max(user_knee_vals) - min(user_knee_vals)
    ref_knee_range = max(1.0, max(ref_knee_vals) - min(ref_knee_vals))

    knee_flex_ratio = user_knee_range / ref_knee_range
    min_flex_ratio = float(groove_cfg.get("min_knee_flex_ratio", 0.65))
    flex_subscore = (
        min(100.0, 100.0 * (knee_flex_ratio / max(0.01, min_flex_ratio)))
        if knee_flex_ratio < min_flex_ratio
        else 100.0
    )

    spine_lag_ms = _estimate_spine_knee_lag_ms(user_features)
    lag_min = float(groove_cfg.get("ideal_spine_lag_ms_min", 30.0))
    lag_max = float(groove_cfg.get("ideal_spine_lag_ms_max", 110.0))
    if lag_min <= spine_lag_ms <= lag_max:
        lag_subscore = 100.0
    elif spine_lag_ms < lag_min:
        lag_subscore = max(0.0, 100.0 * (spine_lag_ms / max(1.0, lag_min)))
    else:
        lag_subscore = max(0.0, 100.0 * (1.0 - (spine_lag_ms - lag_max) / 100.0))

    user_dsj = _compute_dimensionless_jerk(user_features)
    ref_dsj = max(1.0, _compute_dimensionless_jerk(ref_features))
    jerk_ratio = user_dsj / ref_dsj
    max_jerk_ratio = float(groove_cfg.get("max_jerk_ratio", 2.5))
    if jerk_ratio <= 1.15:
        smooth_subscore = 100.0
    else:
        smooth_subscore = max(
            0.0,
            100.0 * (1.0 - (jerk_ratio - 1.15) / max(0.1, max_jerk_ratio - 1.15)),
        )

    groove_score = 0.45 * flex_subscore + 0.30 * lag_subscore + 0.25 * smooth_subscore
    return {
        "groove_score": round(groove_score, 2),
        "knee_flex_ratio": round(knee_flex_ratio, 3),
        "spine_lag_ms": spine_lag_ms,
        "dimensionless_jerk": user_dsj,
        "jerk_ratio": round(jerk_ratio, 3),
    }


def score_attempt(
    attempt_clip: Dict[str, Any],
    reference_clip: Dict[str, Any],
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Full deterministic scoring pipeline for a single attempt vs. reference move."""
    if config is None:
        config = load_config()

    thresholds = config["scoring_thresholds"]
    min_conf = float(thresholds["coverage"]["min_joint_confidence"])
    min_valid_ratio = float(thresholds["coverage"]["min_valid_frame_ratio"])
    coverage_ratio = score_coverage(attempt_clip["frames"], min_conf)
    foot_coverage_ratio = score_foot_coverage(attempt_clip["frames"], min_conf)
    foot_scoring_status = "available" if foot_coverage_ratio >= min_valid_ratio else "unavailable"

    user_gravity: Vec3 = tuple(attempt_clip.get("gravity_vector", (0.0, -1.0, 0.0)))  # type: ignore[assignment]
    ref_gravity: Vec3 = tuple(reference_clip.get("gravity_vector", (0.0, -1.0, 0.0)))  # type: ignore[assignment]
    mirror = bool(attempt_clip.get("mirrored", False))

    user_features = [
        extract_frame_features(f, user_gravity, mirror=mirror) for f in attempt_clip["frames"]
    ]
    ref_features = [
        extract_frame_features(f, ref_gravity, mirror=False) for f in reference_clip["frames"]
    ]

    beat_times = [float(b) for b in reference_clip["beat_times"]]
    bpm = float(reference_clip["bpm"])
    audio_latency_ms = float(attempt_clip.get("audio_latency_ms", 0.0))

    timing_res = score_timing(
        user_features,
        ref_features,
        beat_times,
        bpm,
        audio_latency_ms,
        thresholds["timing"],
    )

    shape_res = score_shape(
        user_features,
        ref_features,
        beat_times,
        timing_res["per_beat"],
        audio_latency_ms,
        thresholds["shape"],
    )
    shape_res["foot_scoring_status"] = foot_scoring_status

    groove_res = score_groove(user_features, ref_features, thresholds["groove"])

    coverage_ok = coverage_ratio >= min_valid_ratio
    timing_ok = timing_res["good_or_better_ratio"] >= float(
        thresholds["gate"]["min_good_or_better_beat_ratio"]
    )
    shape_ok = shape_res["shape_score"] >= float(thresholds["shape"]["pass_min_score"])
    groove_ok = groove_res["groove_score"] >= float(thresholds["groove"]["pass_min_score"])

    passed = bool(coverage_ok and timing_ok and shape_ok and groove_ok)

    # Determine single top deterministic issue citing count, offset in ms, and joint
    wb = timing_res["worst_beat"]
    wj = shape_res["worst_joints"][0]
    if not coverage_ok:
        if foot_scoring_status == "unavailable":
            top_issue = (
                f"Foot keypoints unavailable (foot coverage {foot_coverage_ratio:.0%}); "
                f"real foot landmarker required to score footwork."
            )
        else:
            top_issue = (
                f"Low tracking coverage ({coverage_ratio:.0%}); step back so head and feet stay in frame."
            )
    elif not shape_ok:
        top_issue = (
            f"Shape error on {wj['joint']} (avg {wj['mean_angle_error_deg']:.1f} deg off, "
            f"worst timing at count {wb['count_number']} by {wb['offset_ms']:+.0f} ms)."
        )
    elif not timing_ok:
        top_issue = (
            f"Timing {wb['judgment'].lower()} on count {wb['count_number']} by {wb['offset_ms']:+.0f} ms "
            f"(primary joint: {wj['joint']})."
        )
    elif not groove_ok:
        top_issue = (
            f"Stiff groove (knee flex {groove_res['knee_flex_ratio']:.0%} of ref, "
            f"spine lag {groove_res['spine_lag_ms']:.0f} ms, count {wb['count_number']} offset {wb['offset_ms']:+.0f} ms)."
        )
    else:
        top_issue = (
            f"Clean pass: {timing_res['good_or_better_ratio']:.0%} beats Good+, "
            f"count {wb['count_number']} within {wb['offset_ms']:+.0f} ms."
        )

    digest = {
        "move_tag": reference_clip["move_tag"],
        "speed_pct": int(attempt_clip.get("speed_pct", 100)),
        "passed": passed,
        "mean_timing_offset_ms": timing_res["mean_offset_ms"],
        "good_or_better_ratio": timing_res["good_or_better_ratio"],
        "shape_score": shape_res["shape_score"],
        "groove_score": groove_res["groove_score"],
        "coverage_ratio": round(coverage_ratio, 3),
        "worst_beat": wb,
        "worst_joints": shape_res["worst_joints"],
        "top_deterministic_issue": top_issue,
    }

    return {
        "clip_id": attempt_clip.get("clip_id", "unknown"),
        "passed": passed,
        "coverage_ratio": round(coverage_ratio, 3),
        "foot_scoring_status": foot_scoring_status,
        "timing": timing_res,
        "shape": shape_res,
        "groove": groove_res,
        "between_rep_digest": digest,
    }


def verify_clap_sync(
    wrist_distances: List[float],
    frame_host_times: List[float],
    audio_onset_host_time: float,
    max_tolerance_ms: float = 30.0,
) -> Dict[str, Any]:
    """Verify camera frame timestamps and audio engine timestamps share the same host clock via a clap test.

    Finds the sub-frame visual hand-clap contact timestamp (minimum of `wrist_distances`)
    and compares it against `audio_onset_host_time` in monotonic host-clock seconds.
    """
    if len(wrist_distances) < 3 or len(wrist_distances) != len(frame_host_times):
        return {"synced": False, "offset_ms": 999.0, "visual_clap_host_time": None}

    min_idx = min(range(len(wrist_distances)), key=lambda i: wrist_distances[i])
    if 0 < min_idx < len(wrist_distances) - 1:
        # Invert distances to use parabolic peak finder for minimum
        t_vis = _parabolic_peak_time(
            frame_host_times[min_idx - 1],
            -wrist_distances[min_idx - 1],
            frame_host_times[min_idx],
            -wrist_distances[min_idx],
            frame_host_times[min_idx + 1],
            -wrist_distances[min_idx + 1],
        )
    else:
        t_vis = frame_host_times[min_idx]

    offset_ms = round((t_vis - audio_onset_host_time) * 1000.0, 2)
    return {
        "synced": abs(offset_ms) <= max_tolerance_ms,
        "offset_ms": offset_ms,
        "visual_clap_host_time": round(t_vis, 5),
    }


def validate_against_schema(payload: Dict[str, Any], schema_name: str, schema_path: Optional[Path] = None) -> Tuple[bool, List[str]]:
    """Deterministic structural validator for Gemini JSON outputs & between-rep digests."""
    if schema_path is None:
        schema_path = Path(__file__).resolve().parent.parent / "schemas" / "gemini_schemas.json"
    with open(schema_path, "r", encoding="utf-8") as f:
        schemas = json.load(f)

    if schema_name not in schemas:
        return False, [f"Unknown schema '{schema_name}'"]

    schema = schemas[schema_name]
    errors: List[str] = []

    def _check(obj: Any, subschema: Dict[str, Any], path: str) -> None:
        expected_type = subschema.get("type")
        if expected_type == "object":
            if not isinstance(obj, dict):
                errors.append(f"{path}: expected object, got {type(obj).__name__}")
                return
            for req in subschema.get("required", []):
                if req not in obj:
                    errors.append(f"{path}: missing required field '{req}'")
            props = subschema.get("properties", {})
            if subschema.get("additionalProperties") is False:
                for k in obj:
                    if k not in props:
                        errors.append(f"{path}: unexpected field '{k}'")
            for k, val in obj.items():
                if k in props:
                    _check(val, props[k], f"{path}.{k}")
        elif expected_type == "array":
            if not isinstance(obj, list):
                errors.append(f"{path}: expected array, got {type(obj).__name__}")
                return
            min_items = subschema.get("minItems", 0)
            max_items = subschema.get("maxItems", 999999)
            if len(obj) < min_items:
                errors.append(f"{path}: array shorter than minItems={min_items}")
            if len(obj) > max_items:
                errors.append(f"{path}: array longer than maxItems={max_items}")
            item_schema = subschema.get("items")
            if item_schema:
                for idx, item in enumerate(obj):
                    _check(item, item_schema, f"{path}[{idx}]")
        elif expected_type == "string":
            if not isinstance(obj, str):
                errors.append(f"{path}: expected string, got {type(obj).__name__}")
                return
            if "enum" in subschema and obj not in subschema["enum"]:
                errors.append(f"{path}: value '{obj}' not in enum {subschema['enum']}")
        elif expected_type == "integer":
            if not isinstance(obj, int) or isinstance(obj, bool):
                errors.append(f"{path}: expected integer, got {type(obj).__name__}")
                return
            if "minimum" in subschema and obj < subschema["minimum"]:
                errors.append(f"{path}: value {obj} < minimum {subschema['minimum']}")
        elif expected_type == "number":
            if not isinstance(obj, (int, float)) or isinstance(obj, bool):
                errors.append(f"{path}: expected number, got {type(obj).__name__}")
        elif expected_type == "boolean":
            if not isinstance(obj, bool):
                errors.append(f"{path}: expected boolean, got {type(obj).__name__}")

    _check(payload, schema, schema_name)
    return (len(errors) == 0), errors


def _measure_clip_leg_scale(clip: Dict[str, Any]) -> float:
    grav: Vec3 = tuple(clip.get("gravity_vector", (0.0, -1.0, 0.0)))  # type: ignore[assignment]
    scales: List[float] = []
    for frame in clip.get("frames", []):
        joints = frame.get("joints", {})
        if all(k in joints for k in ("leftHip", "leftKnee", "leftAnkle", "rightHip", "rightKnee", "rightAnkle")):
            lh = apply_gravity_correction(tuple(joints["leftHip"]), grav)  # type: ignore[arg-type]
            lk = apply_gravity_correction(tuple(joints["leftKnee"]), grav)  # type: ignore[arg-type]
            la = apply_gravity_correction(tuple(joints["leftAnkle"]), grav)  # type: ignore[arg-type]
            rh = apply_gravity_correction(tuple(joints["rightHip"]), grav)  # type: ignore[arg-type]
            rk = apply_gravity_correction(tuple(joints["rightKnee"]), grav)  # type: ignore[arg-type]
            ra = apply_gravity_correction(tuple(joints["rightAnkle"]), grav)  # type: ignore[arg-type]
            s = 0.5 * ((_norm(_sub(lk, lh)) + _norm(_sub(la, lk))) + (_norm(_sub(rk, rh)) + _norm(_sub(ra, rk))))
            scales.append(s)
    return round(sum(scales) / max(1, len(scales)), 4)


def calibrate_user_baseline(
    clips: List[Dict[str, Any]],
    references: Dict[str, Dict[str, Any]],
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Ingest ~20 short 20-second calibration clips to calibrate personal baseline and verify pass/fail separation."""
    if config is None:
        config = load_config()

    clean_leg_scales: List[float] = []
    clean_timing_offsets: List[float] = []
    clean_knee_flex_ratios: List[float] = []
    clean_spine_lags: List[float] = []
    clean_groove_scores: List[float] = []

    positive_total = 0
    positive_passed = 0
    negative_total = 0
    negative_rejected = 0
    per_clip_results: List[Dict[str, Any]] = []

    for clip in clips:
        ref = references[clip["move_tag"]]
        res = score_attempt(clip, ref, config)
        expected_pass = bool(clip.get("expected", {}).get("passed", True))
        actual_pass = bool(res["passed"])

        if expected_pass:
            positive_total += 1
            if actual_pass:
                positive_passed += 1
            if abs(res["timing"]["mean_offset_ms"]) <= 30.0:
                clean_leg_scales.append(_measure_clip_leg_scale(clip))
                clean_timing_offsets.append(res["timing"]["mean_offset_ms"])
                clean_knee_flex_ratios.append(res["groove"]["knee_flex_ratio"])
                clean_spine_lags.append(res["groove"]["spine_lag_ms"])
                clean_groove_scores.append(res["groove"]["groove_score"])
        else:
            negative_total += 1
            if not actual_pass:
                negative_rejected += 1

        per_clip_results.append(
            {
                "clip_id": res["clip_id"],
                "expected_pass": expected_pass,
                "actual_pass": actual_pass,
                "matched": expected_pass == actual_pass,
                "mean_offset_ms": res["timing"]["mean_offset_ms"],
                "shape_score": res["shape"]["shape_score"],
                "groove_score": res["groove"]["groove_score"],
                "coverage_ratio": res["coverage_ratio"],
            }
        )

    matched_clips = positive_passed + negative_rejected
    total_clips = max(1, len(clips))
    separation_accuracy = round(matched_clips / total_clips, 4)
    clean_pass_rate = round(positive_passed / max(1, positive_total), 4)
    negative_rejection_rate = round(negative_rejected / max(1, negative_total), 4)

    baseline_groove = (
        round(sum(clean_groove_scores) / len(clean_groove_scores), 2)
        if clean_groove_scores
        else 75.0
    )
    recommended_groove_gate = round(max(60.0, min(75.0, 0.65 * baseline_groove)), 1)

    return {
        "calibration_valid": bool(separation_accuracy == 1.0 and len(clips) >= 4),
        "total_clips": len(clips),
        "matched_clips": matched_clips,
        "separation_accuracy": separation_accuracy,
        "clean_pass_rate": clean_pass_rate,
        "negative_rejection_rate": negative_rejection_rate,
        "learner_baseline": {
            "personal_leg_scale_m": round(
                sum(clean_leg_scales) / max(1, len(clean_leg_scales)), 4
            ),
            "baseline_timing_bias_ms": round(
                sum(clean_timing_offsets) / max(1, len(clean_timing_offsets)), 2
            ),
            "baseline_knee_flex_ratio": round(
                sum(clean_knee_flex_ratios) / max(1, len(clean_knee_flex_ratios)), 3
            ),
            "baseline_spine_lag_ms": round(
                sum(clean_spine_lags) / max(1, len(clean_spine_lags)), 2
            ),
            "baseline_groove_score": baseline_groove,
            "recommended_groove_gate": recommended_groove_gate,
        },
        "clip_results": per_clip_results,
    }

