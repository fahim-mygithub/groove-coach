"""Unit test suite for Groove Coach Milestone 0 scoring functions."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from groove_eval.audio_beats import (
    attach_beats_to_pose_json,
    write_synthetic_click_track_wav,
)
from groove_eval.generate_golden_clips import generate_golden_dataset
from groove_eval.scoring import (
    REQUIRED_FOOT_JOINTS,
    apply_gravity_correction,
    calibrate_user_baseline,
    detect_turnaround_times,
    detect_velocity_peak_times,
    extract_frame_features,
    load_config,
    score_attempt,
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


if __name__ == "__main__":
    unittest.main()


