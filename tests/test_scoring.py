"""Unit test suite for Groove Coach Milestone 0 scoring functions."""

from __future__ import annotations

import copy
import json
import math
import tempfile
import unittest
from pathlib import Path

from groove_eval.audio_beats import (
    attach_beats_to_pose_json,
    write_synthetic_click_track_wav,
)
from groove_eval import lesson_package
from groove_eval.generate_golden_clips import generate_golden_dataset
from groove_eval.generate_lesson_clips import generate_lesson_dataset
from groove_eval.scoring import (
    REQUIRED_FOOT_JOINTS,
    apply_gravity_correction,
    calibrate_user_baseline,
    deep_merge,
    detect_turnaround_times,
    detect_velocity_peak_times,
    extract_frame_features,
    load_config,
    merge_config,
    score_attempt,
    torso_frame_arm_vectors,
    validate_against_schema,
    verify_clap_sync,
)


class TestGrooveCoachScoringM0(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        cls.dataset = generate_golden_dataset()
        cls.references = cls.dataset["references"]
        cls.clips_by_id = {c["clip_id"]: c for c in cls.dataset["golden_clips"]}

    def test_01_turnaround_vs_velocity_peak_timing(self) -> None:
        """Verify turnaround-phase timing lands on the beat while velocity peaks land mid-way between beats."""
        ref = self.references["down_bounce"]
        grav = tuple(ref["gravity_vector"])
        feats = [extract_frame_features(f, grav) for f in ref["frames"]]
        beat_times = ref["beat_times"]
        period = 60.0 / ref["bpm"]

        turnarounds = detect_turnaround_times(feats, beat_times, period)
        vel_peaks = detect_velocity_peak_times(feats, beat_times, period)

        for b_t, t_turn, t_vel in zip(beat_times, turnarounds, vel_peaks):
            self.assertIsNotNone(t_turn)
            self.assertIsNotNone(t_vel)
            # Turnaround (velocity zero-crossing at bottom of dip) is within 10 ms of the beat
            self.assertLessEqual(abs((t_turn - b_t) * 1000.0), 10.0)
            # Velocity peak occurs midway between the "and" and the beat (>85 ms off the beat!)
            self.assertGreater(abs((t_vel - b_t) * 1000.0), 85.0)

    def test_02_coremotion_gravity_tilt_invariance(self) -> None:
        """Verify a 22-deg tilted phone camera recovers the exact same angles after CoreMotion gravity rotation."""
        clean = self.clips_by_id["clip_01_bounce_clean_perfect"]
        tilted = self.clips_by_id["clip_02_bounce_clean_tilted_phone_22deg"]
        ref = self.references["down_bounce"]

        res_clean = score_attempt(clean, ref, self.config)
        res_tilted = score_attempt(tilted, ref, self.config)

        self.assertTrue(res_clean["passed"])
        self.assertTrue(res_tilted["passed"])
        self.assertAlmostEqual(res_clean["shape"]["shape_score"], res_tilted["shape"]["shape_score"], delta=1.5)

    def test_03_late_take_not_double_penalized_on_shape(self) -> None:
        """Verify +145 ms late take fails Timing but still scores high on phase-shifted Shape."""
        late_clip = self.clips_by_id["clip_07_bounce_late_145ms"]
        ref = self.references["down_bounce"]
        res = score_attempt(late_clip, ref, self.config)

        self.assertFalse(res["passed"])
        self.assertAlmostEqual(res["timing"]["mean_offset_ms"], 145.0, delta=8.0)
        self.assertEqual(res["timing"]["good_or_better_ratio"], 0.0)
        self.assertGreaterEqual(res["shape"]["shape_score"], 90.0)

    def test_04_stiff_takes_fail_groove_score(self) -> None:
        """Verify locked knees and zero spine-to-knee phase lag fail the groove gate."""
        for cid in (
            "clip_09_bounce_stiff_locked_knees",
            "clip_10_bounce_stiff_jerky_robot",
            "clip_17_jack_stiff_no_spine_ripple",
        ):
            clip = self.clips_by_id[cid]
            ref = self.references[clip["move_tag"]]
            res = score_attempt(clip, ref, self.config)
            self.assertFalse(res["passed"], f"{cid} should fail")
            self.assertLess(res["groove"]["groove_score"], self.config["scoring_thresholds"]["groove"]["pass_min_score"])

    def test_05_coreml_foot_keypoints_catch_missing_footwork(self) -> None:
        """Verify missing/inverted heel-toe footwork fails Shape even when upper-body jack is clean."""
        clip = self.clips_by_id["clip_18_jack_missing_footwork_flat_feet"]
        ref = self.references["house_jack"]
        res = score_attempt(clip, ref, self.config)

        self.assertFalse(res["passed"])
        self.assertLess(res["shape"]["shape_score"], self.config["scoring_thresholds"]["shape"]["pass_min_score"])
        worst_joint_names = [j["joint"] for j in res["shape"]["worst_joints"][:2]]
        self.assertTrue("left_foot" in worst_joint_names or "right_foot" in worst_joint_names)

    def test_06_all_20_golden_clips_match_expected_labels(self) -> None:
        """Verify all 20 golden clips match their expected pass/fail outcome and emit valid digests."""
        for clip in self.dataset["golden_clips"]:
            ref = self.references[clip["move_tag"]]
            res = score_attempt(clip, ref, self.config)
            self.assertEqual(
                res["passed"],
                clip["expected"]["passed"],
                f"Mismatch on {clip['clip_id']}: got {res['passed']}, digest={res['between_rep_digest']}",
            )
            ok, errs = validate_against_schema(res["between_rep_digest"], "between_rep_digest")
            self.assertTrue(ok, f"Schema error on {clip['clip_id']}: {errs}")

    def test_07_gemini_response_schema_validator_rejects_missing_evidence(self) -> None:
        """Verify invalid Gemini critiques (missing count/ms/joint citation) are rejected deterministically."""
        valid_critique = {
            "single_correction": "Soften your knees on count 3; you landed 145 ms late.",
            "evidence": {
                "count_number": 3,
                "measured_offset_ms": 145.0,
                "joint": "knees",
                "angle_error_deg": 4.2,
            },
            "why_it_happens": "You waited for the snare before starting the downward dip.",
            "isolation_drill": "Half-speed down-bounce counting the 'and' before every beat.",
            "tracking_or_wrong_move_flag": "none",
        }
        ok, errs = validate_against_schema(valid_critique, "post_set_critique_response")
        self.assertTrue(ok, f"Expected valid critique to pass: {errs}")

        invalid_critique = {
            "single_correction": "Great job, keep grooving!",
            "evidence": {"count_number": 3},  # missing measured_offset_ms and joint!
            "why_it_happens": "N/A",
            "isolation_drill": "None",
            "tracking_or_wrong_move_flag": "none",
        }
        ok_bad, errs_bad = validate_against_schema(invalid_critique, "post_set_critique_response")
        self.assertFalse(ok_bad)
        self.assertTrue(any("measured_offset_ms" in e for e in errs_bad))

    def test_08_calibrate_user_baseline_from_20_clips(self) -> None:
        """Verify ingesting the 20 calibration clips computes personal baseline and 100% separation."""
        report = calibrate_user_baseline(
            self.dataset["golden_clips"],
            self.references,
            self.config,
        )
        self.assertTrue(report["calibration_valid"])
        self.assertEqual(report["total_clips"], 20)
        self.assertEqual(report["matched_clips"], 20)
        self.assertEqual(report["separation_accuracy"], 1.0)
        self.assertEqual(report["clean_pass_rate"], 1.0)
        self.assertEqual(report["negative_rejection_rate"], 1.0)
        baseline = report["learner_baseline"]
        self.assertGreater(baseline["personal_leg_scale_m"], 0.75)
        self.assertAlmostEqual(baseline["baseline_spine_lag_ms"], 66.7, delta=5.0)

    def test_09_missing_foot_joints_report_unavailable_no_fake_fallback(self) -> None:
        """Verify missing foot keypoints report 'unavailable' with 0 coverage instead of faking ankle offsets."""
        no_feet_clip = copy.deepcopy(self.clips_by_id["clip_13_jack_clean_perfect"])
        for frame in no_feet_clip["frames"]:
            for fj in REQUIRED_FOOT_JOINTS:
                frame["joints"].pop(fj, None)
                frame["confidences"][fj] = 0.0

        ref = self.references["house_jack"]
        res = score_attempt(no_feet_clip, ref, self.config)
        self.assertEqual(res["foot_scoring_status"], "unavailable")
        self.assertEqual(res["shape"]["foot_scoring_status"], "unavailable")
        self.assertEqual(res["coverage_ratio"], 0.0)
        self.assertFalse(res["passed"])
        self.assertIn("unavailable", res["between_rep_digest"]["top_deterministic_issue"])

    def test_10_clap_sync_host_time_alignment(self) -> None:
        """Verify visual wrist-contact minimum and audio onset align on monotonic host time within +/-30 ms."""
        frame_times = [10.000, 10.0167, 10.0333, 10.0500, 10.0667]
        wrist_dists = [0.35, 0.14, 0.02, 0.15, 0.36]  # Visual clap contact at ~10.0330s
        res_ok = verify_clap_sync(wrist_dists, frame_times, audio_onset_host_time=10.0360, max_tolerance_ms=30.0)
        self.assertTrue(res_ok["synced"])
        self.assertLessEqual(abs(res_ok["offset_ms"]), 10.0)

        res_bad = verify_clap_sync(wrist_dists, frame_times, audio_onset_host_time=10.1200, max_tolerance_ms=30.0)
        self.assertFalse(res_bad["synced"])
        self.assertGreater(abs(res_bad["offset_ms"]), 70.0)

    def test_11_audio_beat_alignment_from_clip_wav(self) -> None:
        """Verify clip-audio beat extraction recovers BPM and beat_times from a clip's audio track."""
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            wav_path = tmp / "take_audio.wav"
            pose_path = tmp / "take_pose.json"
            true_beats = write_synthetic_click_track_wav(
                wav_path, bpm=120.0, num_beats=8, phase_offset_s=0.37
            )
            clip_copy = copy.deepcopy(self.clips_by_id["clip_01_bounce_clean_perfect"])
            clip_copy["beat_times"] = []
            with open(pose_path, "w", encoding="utf-8") as f:
                json.dump(clip_copy, f)

            updated = attach_beats_to_pose_json(wav_path, pose_path)
            self.assertAlmostEqual(updated["bpm"], 120.0, delta=1.5)
            self.assertGreaterEqual(len(updated["beat_times"]), 8)
            for b_true, b_est in zip(true_beats, updated["beat_times"][:8]):
                self.assertLessEqual(abs(b_true - b_est) * 1000.0, 20.0)


class TestLessonScoringKeys(unittest.TestCase):
    """Spec 3.2 keys (`shape.arm_weight`, `gate.timing_source`) and the config deep merge.

    Swift mirror: ios/GrooveCore/Tests/GrooveCoreTests/ScoringEngineTests.swift (fixtures/lesson_clips.json)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        ds = generate_lesson_dataset()
        cls.refs = ds["references"]
        cls.clips = {c["clip_id"]: c for c in ds["golden_clips"]}

    def _score(self, clip_id: str, *extra: dict) -> dict:
        clip = self.clips[clip_id]
        cfg = merge_config(self.config, clip.get("config_overrides"), *extra)
        return score_attempt(clip, self.refs[clip["move_tag"]], cfg)

    def test_deep_merge_matches_lesson_package(self) -> None:
        base = {"a": {"b": 1, "c": {"d": 2}}, "e": [1, 2], "f": 3}
        override = {"a": {"c": {"d": 5, "g": 6}}, "e": [9], "f": {"h": 1}}
        merged = deep_merge(base, override)
        self.assertEqual(merged, {"a": {"b": 1, "c": {"d": 5, "g": 6}}, "e": [9], "f": {"h": 1}})
        self.assertEqual(merged, lesson_package.deep_merge(base, override))
        self.assertEqual(base["a"]["c"], {"d": 2})  # inputs untouched
        manifest = lesson_package.load_manifest(
            Path(__file__).resolve().parent.parent / "fixtures" / "lessons" / "example_manifest.json"
        )
        seg = lesson_package.segment(manifest, "C")
        self.assertEqual(
            merge_config(self.config, manifest["config_overrides"], seg["config_overrides"]),
            lesson_package.segment_config(self.config, manifest, "C"),
        )
        self.assertEqual(merge_config(self.config), self.config)
        self.assertEqual(merge_config(self.config, None, {}), self.config)

    def test_bundled_config_keeps_new_keys_off(self) -> None:
        st = self.config["scoring_thresholds"]
        self.assertNotIn("arm_weight", st["shape"])  # spec 3.2 keys default in code (pinned by test_lesson_package)
        self.assertNotIn("timing_source", st["gate"])
        self.assertEqual(st["retarget"], {"enabled": False})
        self.assertEqual(st["tolerance"]["velocity_scale"], 0.0)
        self.assertEqual(st["tolerance"]["occlusion"]["factor"], 1.0)
        self.assertFalse(st["tolerance"]["occlusion"]["mask"])
        for key in ("scoring_thresholds.shape.arm_weight", "scoring_thresholds.gate.timing_source",
                    "scoring_thresholds.retarget.enabled", "scoring_thresholds.tolerance.velocity_scale",
                    "scoring_thresholds.tolerance.occlusion"):
            self.assertIn(key, self.config["_notes"])

    def test_explicit_defaults_are_no_ops(self) -> None:
        defaults = {"scoring_thresholds": {"shape": {"arm_weight": 0.0}, "gate": {"timing_source": "bounce"}}}
        golden = generate_golden_dataset()
        clip = golden["golden_clips"][0]
        ref = golden["references"][clip["move_tag"]]
        self.assertEqual(score_attempt(clip, ref, self.config), score_attempt(clip, ref, merge_config(self.config, defaults)))

    def test_torso_frame_cancels_yaw(self) -> None:
        pose = {
            "leftHip": [-0.1, 0.0, 0.0], "rightHip": [0.1, 0.0, 0.0], "centerShoulder": [0.0, 0.5, 0.0],
            "leftShoulder": [-0.18, 0.5, 0.0], "leftElbow": [-0.46, 0.5, 0.0], "leftWrist": [-0.46, 0.76, 0.0],
        }
        c, s = math.cos(0.7), math.sin(0.7)
        yawed = {k: [v[0] * c + v[2] * s, v[1], -v[0] * s + v[2] * c] for k, v in pose.items()}
        a, b = torso_frame_arm_vectors(pose), torso_frame_arm_vectors(yawed)
        self.assertEqual(sorted(a), ["leftForearm", "leftUpperArm"])
        for bone in a:
            for k in range(3):
                self.assertAlmostEqual(a[bone][k], b[bone][k], places=12)
        degenerate = {"leftHip": [0.0, 0.0, 0.0], "rightHip": [0.0, 0.0, 0.0], "centerShoulder": [0.0, 1.0, 0.0]}
        self.assertIsNone(torso_frame_arm_vectors(degenerate))

    def test_wrong_arm_direction_same_elbow_angle(self) -> None:
        flat = self._score("lesson_01_arm_gather_unweighted")
        weighted = self._score("lesson_02_arm_gather_weighted")
        right = self._score("lesson_03_arm_ear_flick_weighted")
        # Same elbow angle: the default shape score cannot tell the gather from the ear flick.
        self.assertTrue(flat["passed"])
        self.assertIsNone(flat["shape"]["arm_error_deg"])
        self.assertNotIn("arms", flat["shape"]["joint_errors"])
        self.assertFalse(weighted["passed"])
        self.assertGreater(weighted["shape"]["arm_error_deg"], 45.0)
        self.assertEqual(weighted["shape"]["worst_joints"][0]["joint"], "arms")
        self.assertIn("Shape error on arms", weighted["between_rep_digest"]["top_deterministic_issue"])
        self.assertTrue(right["passed"])
        self.assertLess(right["shape"]["arm_error_deg"], 5.0)
        self.assertGreaterEqual(right["shape"]["shape_score"], 95.0)

    def test_arm_weight_renormalises_the_shape_weights(self) -> None:
        res = self._score("lesson_03_arm_ear_flick_weighted")
        errs = res["shape"]["joint_errors"]
        max_err = self.config["scoring_thresholds"]["shape"]["max_angle_error_deg"]
        comp = {k: max(0.0, 100.0 * (1.0 - v / max_err)) for k, v in errs.items()}
        w = {"knees": 0.30, "spine": 0.25, "hips": 0.15, "left_foot": 0.15, "right_foot": 0.15}
        expected = sum(0.65 * w[k] * comp[k] for k in w) + 0.35 * comp["arms"]
        self.assertAlmostEqual(res["shape"]["shape_score"], expected, delta=0.05)

    def test_arm_only_hits_timing_source(self) -> None:
        bounce = self._score("lesson_04_arm_only_bounce_gate")
        hits = self._score("lesson_05_arm_only_hits_gate")
        late = self._score("lesson_06_arm_only_hits_late")
        self.assertEqual(bounce["timing"]["good_or_better_ratio"], 0.0)  # no knee bounce: every beat a Miss
        self.assertFalse(bounce["passed"])
        self.assertEqual(bounce["timing_gate"], {"source": "bounce", "passed": False, "bounce_passed": False})
        self.assertTrue(hits["passed"])
        self.assertEqual(hits["timing_gate"], {"source": "hits", "passed": True, "bounce_passed": False})
        self.assertEqual(hits["hits"]["on_beat_ratio"], 1.0)
        self.assertIn("of accents on the beat", hits["between_rep_digest"]["top_deterministic_issue"])
        self.assertFalse(late["passed"])
        self.assertFalse(late["timing_gate"]["passed"])
        self.assertTrue(late["between_rep_digest"]["top_deterministic_issue"].startswith("Hit timing off"))

    def test_hits_source_without_reference_hits_never_fails_timing(self) -> None:
        golden = generate_golden_dataset()
        clip = next(c for c in golden["golden_clips"] if c["clip_id"] == "clip_07_bounce_late_145ms")
        ref = golden["references"][clip["move_tag"]]
        hits_cfg = merge_config(self.config, {"scoring_thresholds": {"gate": {"timing_source": "hits"}}})
        res = score_attempt(clip, ref, hits_cfg)
        self.assertEqual(res["hits"]["status"], "not_applicable")
        self.assertTrue(res["timing_gate"]["passed"])
        self.assertFalse(res["timing_gate"]["bounce_passed"])


if __name__ == "__main__":
    unittest.main()


