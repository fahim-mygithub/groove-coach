"""Calibration v2 (`groove.calibration/2`) scoring & retargeting parity tests (spec §8, §9.1, §10 order #11).

Swift mirror: ios/GrooveCore/Tests/GrooveCoreTests/ScoringCalibrationV2Tests.swift.
"""

from __future__ import annotations

import copy
import json
import math
import subprocess
import sys
import unittest
from pathlib import Path
from typing import Any, Dict, List

from groove_eval import retarget
from groove_eval.generate_lesson_clips import generate_lesson_dataset
from groove_eval.scoring import (
    DEFAULT_RETARGET,
    joint_confidence_weight,
    load_config,
    max_upper_arm_elevation_deg,
    measure_clip_leg_scale,
    merge_config,
    sanitized_metric_scale,
    score_attempt,
    shape_group_confidence_weight,
)

ROOT = Path(__file__).resolve().parent.parent


def _make_canonical_frame(
    t: float,
    scale: float = 1.0,
    knee_flex_deg: float = 8.0,
    spine_jack_deg: float = 4.0,
    trunk_lean_deg: float = 2.0,
    left_foot_pitch_deg: float = 0.0,
    right_foot_pitch_deg: float = 0.0,
    arm_elevation_deg: float = 20.0,
    elbow_flex_deg: float = 0.0,
    wrist_slide_x: float = 0.0,
) -> Dict[str, Any]:
    """1:1 mirror of `ScoringCalibrationV2Tests.makeCanonicalFrame` in Swift."""
    lower_rad = math.radians(trunk_lean_deg - 0.5 * spine_jack_deg)
    upper_rad = math.radians(trunk_lean_deg + 0.5 * spine_jack_deg)
    spine_len = 0.25 * scale
    spine = [0.0, spine_len * math.cos(lower_rad), spine_len * math.sin(lower_rad)]
    center_shoulder = [
        0.0,
        spine[1] + spine_len * math.cos(upper_rad),
        spine[2] + spine_len * math.sin(upper_rad),
    ]

    half_flex_rad = math.radians(0.5 * knee_flex_deg)
    thigh_len = 0.42 * scale
    shin_len = 0.40 * scale
    hip_x = 0.11 * scale
    knee_y = -thigh_len * math.cos(half_flex_rad)
    knee_z = thigh_len * math.sin(half_flex_rad)
    ankle_y = knee_y - shin_len * math.cos(half_flex_rad)
    ankle_z = knee_z - shin_len * math.sin(half_flex_rad)

    foot_len = 0.16 * scale
    l_pitch_rad = math.radians(left_foot_pitch_deg)
    r_pitch_rad = math.radians(right_foot_pitch_deg)
    l_heel = [-hip_x, ankle_y - 0.04 * scale, ankle_z - 0.04 * scale]
    r_heel = [hip_x, ankle_y - 0.04 * scale, ankle_z - 0.04 * scale]
    l_foot_idx = [l_heel[0], l_heel[1] + foot_len * math.sin(l_pitch_rad), l_heel[2] + foot_len * math.cos(l_pitch_rad)]
    r_foot_idx = [r_heel[0], r_heel[1] + foot_len * math.sin(r_pitch_rad), r_heel[2] + foot_len * math.cos(r_pitch_rad)]

    shoulder_half_w = 0.18 * scale
    l_shoulder = [-shoulder_half_w, center_shoulder[1], center_shoulder[2]]
    r_shoulder = [shoulder_half_w, center_shoulder[1], center_shoulder[2]]

    elev_rad = math.radians(arm_elevation_deg)
    fore_rad = math.radians(arm_elevation_deg + elbow_flex_deg)
    upper_arm_len = 0.28 * scale
    forearm_len = 0.26 * scale

    l_elbow = [
        l_shoulder[0] - upper_arm_len * math.sin(elev_rad),
        l_shoulder[1] - upper_arm_len * math.cos(elev_rad),
        l_shoulder[2],
    ]
    r_elbow = [
        r_shoulder[0] + upper_arm_len * math.sin(elev_rad),
        r_shoulder[1] - upper_arm_len * math.cos(elev_rad),
        r_shoulder[2],
    ]
    l_wrist = [
        l_elbow[0] - forearm_len * math.sin(fore_rad) + wrist_slide_x,
        l_elbow[1] - forearm_len * math.cos(fore_rad),
        l_elbow[2],
    ]
    r_wrist = [
        r_elbow[0] + forearm_len * math.sin(fore_rad) + wrist_slide_x,
        r_elbow[1] - forearm_len * math.cos(fore_rad),
        r_elbow[2],
    ]

    joints = {
        "root": [0.0, 0.0, 0.0],
        "spine": spine,
        "centerShoulder": center_shoulder,
        "nose": [0.0, center_shoulder[1] + 0.20 * scale, center_shoulder[2] + 0.02 * scale],
        "leftHip": [-hip_x, 0.0, 0.0],
        "leftKnee": [-hip_x, knee_y, knee_z],
        "leftAnkle": [-hip_x, ankle_y, ankle_z],
        "leftHeel": l_heel,
        "leftFootIndex": l_foot_idx,
        "rightHip": [hip_x, 0.0, 0.0],
        "rightKnee": [hip_x, knee_y, knee_z],
        "rightAnkle": [hip_x, ankle_y, ankle_z],
        "rightHeel": r_heel,
        "rightFootIndex": r_foot_idx,
        "leftShoulder": l_shoulder,
        "leftElbow": l_elbow,
        "leftWrist": l_wrist,
        "rightShoulder": r_shoulder,
        "rightElbow": r_elbow,
        "rightWrist": r_wrist,
    }
    return {"t": t, "joints": joints, "confidences": {k: 0.95 for k in joints}}


class TestCalibrationV2ScoringParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        cls.no_smooth_cfg = merge_config(cls.config, {"scoring_thresholds": {"smoothing": {"enabled": False}}})
        cls.dataset = generate_lesson_dataset()
        cls.refs = cls.dataset["references"]
        cls.clips = {c["clip_id"]: c for c in cls.dataset["golden_clips"]}

    def test_calibration_v2_preserves_retarget_disabled_default(self) -> None:
        self.assertEqual(DEFAULT_RETARGET, {"enabled": False})
        self.assertEqual(self.config["scoring_thresholds"]["retarget"], {"enabled": False})

        uncalibrated = self.clips["lesson_12_retarget_off"]
        ref = self.refs[uncalibrated["move_tag"]]
        learner_bones = retarget.median_bone_lengths(uncalibrated["frames"])

        calibrated_neutral = dict(
            uncalibrated,
            calibration_v2={"schema": "groove.calibration/2", "metricScaleFactor": 1.0, "boneLengthsM": learner_bones},
        )
        base_res = score_attempt(uncalibrated, ref, self.config)
        cal_res = score_attempt(calibrated_neutral, ref, self.config)

        self.assertFalse(base_res["retargeted"])
        self.assertFalse(cal_res["retargeted"])
        self.assertEqual(cal_res["passed"], base_res["passed"])
        self.assertAlmostEqual(cal_res["shape"]["shape_score"], base_res["shape"]["shape_score"], places=12)
        self.assertAlmostEqual(cal_res["groove"]["groove_score"], base_res["groove"]["groove_score"], places=12)
        self.assertEqual(cal_res["joints"]["counts"], base_res["joints"]["counts"])
        self.assertEqual(
            [v["error"] for v in cal_res["joints"]["verdicts"]],
            [v["error"] for v in base_res["joints"]["verdicts"]],
        )
        flagged = {v["joint"] for v in cal_res["joints"]["verdicts"] if v["severity"] != "ok"}
        self.assertTrue({"leftWrist", "rightWrist"} <= flagged)

    def test_calibration_v2_bone_lengths_priority_when_retarget_enabled(self) -> None:
        take_frame = _make_canonical_frame(0.0, scale=1.0)
        stance_frame = _make_canonical_frame(0.0, scale=1.2)
        v2_bones = {
            "spine": 0.36,
            "leftWrist": 0.33,
            "rightWrist": 0.25,
            "nose": 0.0,
            "leftHeel": -0.1,
            "rightHeel": float("nan"),
        }
        clip = {
            "clip_id": "priority_all",
            "move_tag": "m",
            "bpm": 112.5,
            "beat_times": [0.5],
            "mirrored": False,
            "frames": [take_frame],
            "calibration_frames": [stance_frame],
            "calibration_v2": {"boneLengthsM": v2_bones},
        }
        from_v2 = retarget.learner_bone_lengths(clip)
        self.assertAlmostEqual(from_v2["spine"], 0.36, places=12)
        self.assertAlmostEqual(from_v2["leftWrist"], 0.33, places=12)
        self.assertAlmostEqual(from_v2["rightWrist"], 0.25, places=12)
        self.assertNotIn("nose", from_v2)
        self.assertNotIn("leftHeel", from_v2)
        self.assertNotIn("rightHeel", from_v2)

        mirrored = retarget.learner_bone_lengths(dict(clip, mirrored=True))
        self.assertAlmostEqual(mirrored["leftWrist"], 0.25, places=12)
        self.assertAlmostEqual(mirrored["rightWrist"], 0.33, places=12)
        self.assertAlmostEqual(mirrored["spine"], 0.36, places=12)

        # Preserve calibration_v2 on retarget_clip
        retargeted_clip = retarget.retarget_clip(clip, {"spine": 0.30})
        self.assertEqual(retargeted_clip["calibration_v2"], clip["calibration_v2"])

        # Empty boneLengthsM falls back to calibration_frames, then frames
        empty_v2 = dict(clip, calibration_v2={"boneLengthsM": {}})
        self.assertAlmostEqual(retarget.learner_bone_lengths(empty_v2)["spine"], 0.25 * 1.2, places=12)
        take_only = dict(empty_v2, calibration_frames=[])
        self.assertAlmostEqual(retarget.learner_bone_lengths(take_only)["spine"], 0.25, places=12)

        # Full score_attempt check: calibration_v2.boneLengthsM wins over wrong calibration_frames
        retarget_on = merge_config(self.config, {"scoring_thresholds": {"retarget": {"enabled": True}}})
        long_attempt = self.clips["lesson_12_retarget_off"]
        short_ref = self.refs[long_attempt["move_tag"]]
        true_bones = retarget.median_bone_lengths(long_attempt["frames"])

        wrong_stance = dict(long_attempt, calibration_frames=[short_ref["frames"][0]])
        wrong_res = score_attempt(wrong_stance, short_ref, retarget_on)
        self.assertTrue(wrong_res["retargeted"])
        self.assertGreater(wrong_res["joints"]["counts"]["warn"] + wrong_res["joints"]["counts"]["off"], 0)

        v2_wins = dict(wrong_stance, calibration_v2={"boneLengthsM": true_bones})
        v2_res = score_attempt(v2_wins, short_ref, retarget_on)
        self.assertTrue(v2_res["retargeted"])
        self.assertEqual(v2_res["joints"]["counts"]["warn"] + v2_res["joints"]["counts"]["off"], 0)

    def test_metric_scale_factor_velocity_and_leg_scale(self) -> None:
        self.assertEqual(sanitized_metric_scale(None), 1.0)
        self.assertEqual(sanitized_metric_scale(0.0), 1.0)
        self.assertEqual(sanitized_metric_scale(-1.2), 1.0)
        self.assertEqual(sanitized_metric_scale(float("nan")), 1.0)
        self.assertEqual(sanitized_metric_scale(float("inf")), 1.0)
        self.assertEqual(sanitized_metric_scale(True), 1.0)
        self.assertEqual(sanitized_metric_scale(1.25), 1.25)

        beat_times = [0.80, 1.80]

        def build_hit_frames(wrist_speed_mps: float) -> List[Dict[str, Any]]:
            x_pos = 0.0
            dt = 1.0 / 30.0
            out: List[Dict[str, Any]] = []
            for i in range(90):
                t = i * dt
                if 16 < i <= 23:
                    x_pos += wrist_speed_mps * dt
                elif 46 < i <= 53:
                    x_pos -= wrist_speed_mps * dt
                out.append(_make_canonical_frame(t, spine_jack_deg=0.0, trunk_lean_deg=0.0, wrist_slide_x=x_pos))
            return out

        ref_clip = {
            "clip_id": "ref_hits",
            "move_tag": "hits_m",
            "bpm": 60.0,
            "beat_times": beat_times,
            "frames": build_hit_frames(3.0),
        }
        uncal_attempt = {
            "clip_id": "usr_uncal",
            "move_tag": "hits_m",
            "bpm": 60.0,
            "beat_times": beat_times,
            "frames": build_hit_frames(1.76),
        }
        scaled_attempt = dict(uncal_attempt, clip_id="usr_scaled", calibration_v2={"metricScaleFactor": 1.25})

        uncal_res = score_attempt(uncal_attempt, ref_clip, self.no_smooth_cfg)
        scaled_res = score_attempt(scaled_attempt, ref_clip, self.no_smooth_cfg)

        self.assertEqual(uncal_res["hits"]["reference_hit_count"], 2)
        self.assertEqual(uncal_res["hits"]["user_hit_count"], 0)
        self.assertEqual(uncal_res["hits"]["matched_count"], 0)
        self.assertEqual(uncal_res["hits"]["hit_score"], 0.0)

        self.assertEqual(scaled_res["hits"]["user_hit_count"], 2)
        self.assertEqual(scaled_res["hits"]["matched_count"], 2)
        self.assertAlmostEqual(scaled_res["hits"]["hit_score"], 100.0, places=6)

        uncal_leg = measure_clip_leg_scale(uncal_attempt)
        scaled_leg = measure_clip_leg_scale(scaled_attempt)
        self.assertAlmostEqual(scaled_leg, round(uncal_leg * 1.25, 4), places=4)
        self.assertAlmostEqual(
            measure_clip_leg_scale({"frames": [], "calibration_v2": {"metricScaleFactor": 1.25}}),
            round(0.82 * 1.25, 4),
            places=4,
        )

    def test_rom_and_confidence_scaling(self) -> None:
        bpm = 100.0
        period = 60.0 / bpm
        beats = [0.6 + k * period for k in range(4)]

        def bounce_frames(
            knee_amp_deg: float,
            trunk_lean_offset_deg: float = 0.0,
            foot_pitch_deg: float = 0.0,
            arm_elevation_deg: float = 20.0,
        ) -> List[Dict[str, Any]]:
            out: List[Dict[str, Any]] = []
            for i in range(95):
                time = i / 30.0
                phase = 2.0 * math.pi * ((time - beats[0]) / period)
                spine_phase = 2.0 * math.pi * ((time - 0.066 - beats[0]) / period)
                wave = 0.5 * (1.0 + math.cos(phase))
                spine_wave = 0.5 * (1.0 + math.cos(spine_phase))
                spine_jack = 4.0 + 12.0 * spine_wave
                out.append(
                    _make_canonical_frame(
                        time,
                        knee_flex_deg=8.0 + knee_amp_deg * wave,
                        spine_jack_deg=spine_jack,
                        trunk_lean_deg=2.0 + trunk_lean_offset_deg,
                        left_foot_pitch_deg=foot_pitch_deg,
                        right_foot_pitch_deg=foot_pitch_deg,
                        arm_elevation_deg=arm_elevation_deg,
                    )
                )
            return out

        deep_ref = {"clip_id": "ref_bounce", "move_tag": "bounce", "bpm": bpm, "beat_times": beats, "frames": bounce_frames(32.0)}
        limited_attempt = {
            "clip_id": "usr_limited_rom",
            "move_tag": "bounce",
            "bpm": bpm,
            "beat_times": beats,
            "frames": bounce_frames(14.0),
        }
        limited_uncal = score_attempt(limited_attempt, deep_ref, self.no_smooth_cfg)
        self.assertLess(limited_uncal["groove"]["knee_flex_ratio"], 0.50)

        limited_cal = score_attempt(
            dict(
                limited_attempt,
                calibration_v2={"rom": {"standingKneeFlexDeg": 6.0, "plieKneeFlexDeg": 26.0, "trunkLeanBaselineDeg": 2.0}},
            ),
            deep_ref,
            self.no_smooth_cfg,
        )
        self.assertAlmostEqual(limited_cal["groove"]["knee_flex_ratio"], 0.70, delta=0.02)
        self.assertGreater(limited_cal["groove"]["groove_score"], limited_uncal["groove"]["groove_score"])

        # Stiff knees (3 deg range) still fail due to 15 deg ROM floor
        stiff_res = score_attempt(
            {
                "clip_id": "usr_stiff",
                "move_tag": "bounce",
                "bpm": bpm,
                "beat_times": beats,
                "frames": bounce_frames(3.0),
                "calibration_v2": {"rom": {"standingKneeFlexDeg": 6.0, "plieKneeFlexDeg": 14.0, "trunkLeanBaselineDeg": 2.0}},
            },
            deep_ref,
            self.no_smooth_cfg,
        )
        self.assertAlmostEqual(stiff_res["groove"]["knee_flex_ratio"], 0.20, delta=0.02)
        self.assertLess(stiff_res["groove"]["knee_flex_ratio"], self.no_smooth_cfg["scoring_thresholds"]["groove"]["min_knee_flex_ratio"])

        # Resting trunk lean baseline (including clamping to [-5, 5])
        posture_attempt = {
            "clip_id": "usr_posture",
            "move_tag": "bounce",
            "bpm": bpm,
            "beat_times": beats,
            "frames": bounce_frames(32.0, trunk_lean_offset_deg=4.0),
        }
        posture_uncal = score_attempt(posture_attempt, deep_ref, self.no_smooth_cfg)
        self.assertAlmostEqual(posture_uncal["shape"]["joint_errors"]["hips"], 4.0, delta=0.05)

        posture_cal = score_attempt(
            dict(
                posture_attempt,
                calibration_v2={"rom": {"standingKneeFlexDeg": 8.0, "plieKneeFlexDeg": 40.0, "trunkLeanBaselineDeg": 6.0}},
            ),
            deep_ref,
            self.no_smooth_cfg,
        )
        self.assertAlmostEqual(posture_cal["shape"]["joint_errors"]["hips"], 0.0, delta=0.05)
        self.assertGreater(posture_cal["shape"]["shape_score"], posture_uncal["shape"]["shape_score"])

        # Overhead tolerance floor (1.25x on elbows & wrists when ref elevation > maxShoulderElevationDeg)
        overhead_ref = {
            "clip_id": "ref_overhead",
            "move_tag": "overhead",
            "bpm": bpm,
            "beat_times": beats,
            "frames": bounce_frames(24.0, arm_elevation_deg=170.0),
        }
        lower_overhead_usr = {
            "clip_id": "usr_overhead",
            "move_tag": "overhead",
            "bpm": bpm,
            "beat_times": beats,
            "frames": bounce_frames(24.0, arm_elevation_deg=145.0),
        }
        overhead_uncal = score_attempt(lower_overhead_usr, overhead_ref, self.no_smooth_cfg)
        overhead_widened = score_attempt(
            dict(lower_overhead_usr, calibration_v2={"rom": {"maxShoulderElevationDeg": 150.0, "trunkLeanBaselineDeg": 2.0}}),
            overhead_ref,
            self.no_smooth_cfg,
        )
        uncal_errs = {v["joint"]: v["error"] for v in overhead_uncal["joints"]["verdicts"]}
        widened_errs = {v["joint"]: v["error"] for v in overhead_widened["joints"]["verdicts"]}
        for arm_joint in ("leftElbow", "rightElbow", "leftWrist", "rightWrist"):
            self.assertGreater(uncal_errs[arm_joint], 0.02)
            self.assertAlmostEqual(widened_errs[arm_joint], uncal_errs[arm_joint] / 1.25, delta=0.001)
        self.assertIsNone(max_upper_arm_elevation_deg({}))

        # Joint verdict tolerance widening (1.0 / clamp(w_j, 0.5, 1.0), mirror & synthesized joint fallback)
        weights = {"leftWrist": 0.50, "rightWrist": 0.80, "leftElbow": 0.25, "leftHip": 0.60, "rightHip": 0.90}
        self.assertAlmostEqual(joint_confidence_weight("leftWrist", weights, mirror=False), 0.50)
        self.assertAlmostEqual(joint_confidence_weight("leftWrist", weights, mirror=True), 0.80)
        self.assertAlmostEqual(joint_confidence_weight("root", weights, mirror=False), 0.60)
        self.assertAlmostEqual(joint_confidence_weight("spine", weights, mirror=False), 0.60)
        self.assertAlmostEqual(shape_group_confidence_weight("spine", weights, mirror=False), (1.0 + 1.0 + 0.6 + 0.9) / 4.0)

        low_conf = score_attempt(
            dict(lower_overhead_usr, calibration_v2={"jointConfidenceWeights": {"leftWrist": 0.50, "rightWrist": 0.80, "leftElbow": 0.25}}),
            overhead_ref,
            self.no_smooth_cfg,
        )
        conf_errs = {v["joint"]: v["error"] for v in low_conf["joints"]["verdicts"]}
        self.assertAlmostEqual(conf_errs["leftWrist"], uncal_errs["leftWrist"] * 0.50, delta=0.001)
        self.assertAlmostEqual(conf_errs["rightWrist"], uncal_errs["rightWrist"] * 0.80, delta=0.001)
        self.assertAlmostEqual(conf_errs["leftElbow"], uncal_errs["leftElbow"] * 0.50, delta=0.001)

        # Shape sub-weight re-normalization (mirrors Swift 88.0 -> 92.94 check)
        noisy_feet = {
            "clip_id": "usr_noisy_feet",
            "move_tag": "bounce",
            "bpm": bpm,
            "beat_times": beats,
            "frames": bounce_frames(32.0, foot_pitch_deg=18.0),
        }
        shape_uncal = score_attempt(noisy_feet, deep_ref, self.no_smooth_cfg)
        self.assertAlmostEqual(shape_uncal["shape"]["shape_score"], 88.0, delta=0.05)

        shape_cal = score_attempt(
            dict(
                noisy_feet,
                calibration_v2={
                    "jointConfidenceWeights": {
                        "leftHeel": 0.50,
                        "leftFootIndex": 0.50,
                        "rightHeel": 0.50,
                        "rightFootIndex": 0.50,
                    }
                },
            ),
            deep_ref,
            self.no_smooth_cfg,
        )
        self.assertAlmostEqual(shape_cal["shape"]["shape_score"], 92.94, delta=0.05)
        self.assertGreater(shape_cal["shape"]["shape_score"], shape_uncal["shape"]["shape_score"])

    def test_lesson_clips_calibration_v2_cases_and_parity_script(self) -> None:
        # Fixture matches generator
        with open(ROOT / "fixtures" / "lesson_clips.json", "r", encoding="utf-8") as f:
            committed = json.load(f)
        self.assertEqual(committed, json.loads(json.dumps(self.dataset)))

        # Case 1: lesson_20_calibration_v2_rom_conf_metric (default retarget.enabled = false)
        c20 = self.clips["lesson_20_calibration_v2_rom_conf_metric"]
        self.assertNotIn("config_overrides", c20)
        ref20 = self.refs[c20["move_tag"]]
        res20_cal = score_attempt(c20, ref20, self.config)
        c20_uncal = copy.deepcopy(c20)
        c20_uncal.pop("calibration_v2", None)
        res20_uncal = score_attempt(c20_uncal, ref20, self.config)

        self.assertTrue(res20_cal["passed"])
        self.assertFalse(res20_cal["retargeted"])
        self.assertEqual(res20_uncal["hits"]["matched_count"], 0)
        self.assertEqual(res20_cal["hits"]["matched_count"], 4)
        self.assertAlmostEqual(res20_cal["hits"]["hit_score"], 100.0, delta=1.0)
        self.assertGreater(res20_cal["groove"]["groove_score"], res20_uncal["groove"]["groove_score"])
        self.assertGreater(res20_cal["shape"]["shape_score"], res20_uncal["shape"]["shape_score"])
        self.assertGreater(res20_cal["joints"]["counts"]["ok"], res20_uncal["joints"]["counts"]["ok"])

        # Case 2: lesson_21_calibration_v2_retarget_bones (retarget.enabled = true via config_overrides)
        c21 = self.clips["lesson_21_calibration_v2_retarget_bones"]
        self.assertEqual(c21["config_overrides"], {"scoring_thresholds": {"retarget": {"enabled": True}}})
        ref21 = self.refs[c21["move_tag"]]
        cfg21 = merge_config(self.config, c21["config_overrides"])
        res21_cal = score_attempt(c21, ref21, cfg21)
        c21_without_v2 = copy.deepcopy(c21)
        c21_without_v2.pop("calibration_v2", None)
        res21_wrong_stance = score_attempt(c21_without_v2, ref21, cfg21)

        self.assertTrue(res21_cal["passed"])
        self.assertTrue(res21_cal["retargeted"])
        self.assertEqual(res21_cal["joints"]["counts"]["warn"] + res21_cal["joints"]["counts"]["off"], 0)
        self.assertGreater(
            res21_wrong_stance["joints"]["counts"]["warn"] + res21_wrong_stance["joints"]["counts"]["off"], 0
        )

        # Canonical snapshot + check_parity.py passes cleanly
        proc = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "check_parity.py")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Python vs. canonical snapshot parity", proc.stdout)


if __name__ == "__main__":
    unittest.main()
