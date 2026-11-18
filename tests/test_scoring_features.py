"""Tests for the wave-2 scoring components: One Euro smoothing, hit timing, joint verdicts and hand styling.

Swift mirror: ios/GrooveCore/Tests/GrooveCoreTests/ScoringFeaturesTests.swift (same fixtures and expectations).
"""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from groove_eval import lesson_package
from groove_eval.generate_feature_clips import generate_feature_dataset
from groove_eval.generate_golden_clips import generate_golden_dataset
from groove_eval.generate_lesson_clips import generate_lesson_dataset
from groove_eval.scoring import (
    DEFAULT_TOLERANCE,
    compute_joint_tolerances,
    deep_merge,
    load_config,
    merge_config,
    reference_velocity_factors,
    score_attempt,
    smooth_frames,
    validate_against_schema,
    windows_at,
)

ROOT = Path(__file__).resolve().parent.parent


class TestScoringFeatures(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        golden = generate_golden_dataset()
        cls.golden_refs = golden["references"]
        cls.golden = {c["clip_id"]: c for c in golden["golden_clips"]}
        features = generate_feature_dataset()
        cls.feature_ref = features["references"]["arm_hits"]
        cls.features = {c["clip_id"]: c for c in features["golden_clips"]}

    def _with(self, section: str, **values: object) -> dict:
        cfg = copy.deepcopy(self.config)
        cfg["scoring_thresholds"][section].update(values)
        return cfg

    def _score_feature(self, clip_id: str, config: dict = None) -> dict:
        return score_attempt(self.features[clip_id], self.feature_ref, config or self.config)

    def test_smoothing_is_configurable_and_keeps_golden_labels(self) -> None:
        clip = self.golden["clip_01_bounce_clean_perfect"]
        ref = self.golden_refs["down_bounce"]
        on = score_attempt(clip, ref, self.config)
        off = score_attempt(clip, ref, self._with("smoothing", enabled=False))
        self.assertTrue(on["smoothing_applied"])
        self.assertFalse(off["smoothing_applied"])
        self.assertTrue(on["passed"] and off["passed"])
        for clip in self.golden.values():
            res = score_attempt(clip, self.golden_refs[clip["move_tag"]], self.config)
            self.assertEqual(res["passed"], clip["expected"]["passed"], clip["clip_id"])

    def test_smoothing_reduces_jitter_and_keeps_timestamps(self) -> None:
        frames = [
            {"t": i / 30.0, "joints": {"root": [0.01 * (-1) ** i, 0.8, 0.0]}, "confidences": {"root": 0.9}}
            for i in range(30)
        ]
        smoothed = smooth_frames(frames, self.config["scoring_thresholds"]["smoothing"])
        self.assertEqual([f["t"] for f in smoothed], [f["t"] for f in frames])
        self.assertEqual(smoothed[5]["confidences"], frames[5]["confidences"])
        raw_jitter = max(abs(f["joints"]["root"][0]) for f in frames[10:])
        smooth_jitter = max(abs(f["joints"]["root"][0]) for f in smoothed[10:])
        self.assertLess(smooth_jitter, 0.5 * raw_jitter)

    def test_continuous_grooves_have_no_hit_component(self) -> None:
        res = score_attempt(self.golden["clip_01_bounce_clean_perfect"], self.golden_refs["down_bounce"], self.config)
        self.assertEqual(res["hits"]["status"], "not_applicable")
        self.assertIsNone(res["hits"]["hit_score"])

    def test_hit_timing_on_beat_late_and_missing(self) -> None:
        clean = self._score_feature("feat_01_hits_clean_open_hands")["hits"]
        late = self._score_feature("feat_02_hits_late_fist_hands")["hits"]
        missing = self._score_feature("feat_03_no_hits_no_hands")["hits"]
        self.assertEqual(clean["status"], "available")
        self.assertEqual(clean["reference_hit_count"], 8)
        self.assertEqual(clean["matched_count"], 8)
        self.assertGreaterEqual(clean["hit_score"], 95.0)
        self.assertLess(abs(clean["mean_offset_ms"]), 40.0)
        self.assertEqual(late["matched_count"], 8)
        self.assertGreater(late["mean_offset_ms"], 80.0)
        self.assertLess(late["hit_score"], 60.0)
        self.assertTrue(all(h["judgment"] in ("Good", "Late") for h in late["per_hit"]))
        self.assertEqual(missing["hit_score"], 0.0)
        self.assertTrue(all(h["judgment"] == "Miss" for h in missing["per_hit"]))

    def test_hit_gate_is_off_by_default_and_can_fail_attempts(self) -> None:
        self.assertTrue(self._score_feature("feat_02_hits_late_fist_hands")["passed"])
        gated = self._score_feature("feat_02_hits_late_fist_hands", self._with("hits", gate=True))
        self.assertFalse(gated["passed"])
        self.assertIn("Hits off the beat", gated["between_rep_digest"]["top_deterministic_issue"])

    def test_joint_verdicts_flag_the_wrong_joint_with_a_hint(self) -> None:
        clean = self._score_feature("feat_01_hits_clean_open_hands")["joints"]
        static_arms = self._score_feature("feat_03_no_hits_no_hands")["joints"]
        self.assertEqual(clean["counts"]["warn"] + clean["counts"]["off"], 0)
        self.assertIsNone(clean["top_hint"])
        flagged = {v["joint"] for v in static_arms["verdicts"] if v["severity"] != "ok"}
        self.assertTrue({"leftWrist", "rightWrist"} <= flagged)
        self.assertIn(static_arms["top_joint"], ("leftWrist", "rightWrist", "leftElbow", "rightElbow"))
        self.assertTrue(static_arms["top_hint"].startswith("raise "))

    def test_joint_verdicts_on_golden_failures(self) -> None:
        stiff = score_attempt(
            self.golden["clip_09_bounce_stiff_locked_knees"], self.golden_refs["down_bounce"], self.config
        )["joints"]
        self.assertEqual(stiff["top_hint"], "bend left knee")
        clean = score_attempt(
            self.golden["clip_03_bounce_clean_mirrored_tall"], self.golden_refs["down_bounce"], self.config
        )["joints"]
        self.assertEqual(clean["counts"]["ok"], len(clean["verdicts"]) + len(clean["angle_verdicts"]))

    def test_golden_takes_widen_tolerances(self) -> None:
        jt = self.config["scoring_thresholds"]["joint_tolerance"]
        ref = self.golden_refs["down_bounce"]
        beats = ref["beat_times"]
        alone = compute_joint_tolerances([ref], beats, jt)
        widened = compute_joint_tolerances([ref, self.golden["clip_04_bounce_good_plus_85ms"]], beats, jt)
        # One looped reference repeats its pose every count: zero spread, so the floors apply.
        self.assertEqual(alone["positions"]["leftKnee"], jt["position_floor"])
        self.assertEqual(alone["angles"]["leftKnee"], jt["angle_floor_deg"])
        # A late clean take samples a different phase of the bounce on each beat: the knee spread widens.
        self.assertGreater(widened["angles"]["leftKnee"], alone["angles"]["leftKnee"])

    def test_hand_styling_scores_shape_and_skips_absent_hands(self) -> None:
        clean = self._score_feature("feat_01_hits_clean_open_hands")["hands"]
        fist = self._score_feature("feat_02_hits_late_fist_hands")["hands"]
        absent = self._score_feature("feat_03_no_hits_no_hands")["hands"]
        mirrored = self._score_feature("feat_04_mirrored_hits_flat_hands")["hands"]
        self.assertEqual((clean["status"], clean["hand_score"], clean["user_shape"]), ("available", 100.0, "open"))
        self.assertEqual(fist["user_shape"], "fist")
        self.assertEqual(fist["reference_shape"], "open")
        self.assertLess(fist["hand_score"], 50.0)
        self.assertEqual(absent["status"], "skipped")
        self.assertIsNone(absent["hand_score"])
        self.assertEqual(mirrored["user_shape"], "flat")
        self.assertLess(mirrored["hand_score"], clean["hand_score"])
        self.assertGreater(mirrored["hand_score"], fist["hand_score"])

    def test_absent_hands_never_fail_a_gated_attempt(self) -> None:
        cfg = self._with("hands", gate=True)
        self.assertTrue(self._score_feature("feat_03_no_hits_no_hands", cfg)["passed"])
        self.assertFalse(self._score_feature("feat_02_hits_late_fist_hands", cfg)["passed"])

    def test_digest_carries_optional_fields_and_validates(self) -> None:
        res = self._score_feature("feat_02_hits_late_fist_hands")
        digest = res["between_rep_digest"]
        self.assertEqual(digest["top_correction_hint"], res["joints"]["top_hint"])
        self.assertEqual(digest["hit_score"], res["hits"]["hit_score"])
        self.assertEqual(digest["hand_score"], res["hands"]["hand_score"])
        ok, errs = validate_against_schema(digest, "between_rep_digest")
        self.assertTrue(ok, errs)
        absent = self._score_feature("feat_03_no_hits_no_hands")["between_rep_digest"]
        self.assertNotIn("hand_score", absent)


class TestLessonFeatures(unittest.TestCase):
    """Windows, rate stretch, velocity and occlusion tolerances on fixtures/lesson_clips.json.

    Swift mirror: ios/GrooveCore/Tests/GrooveCoreTests/ScoringFeaturesTests.swift (same clips and expectations)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        cls.dataset = generate_lesson_dataset()
        cls.refs = cls.dataset["references"]
        cls.clips = {c["clip_id"]: c for c in cls.dataset["golden_clips"]}

    def _score(self, clip_id: str) -> dict:
        clip = self.clips[clip_id]
        return score_attempt(clip, self.refs[clip["move_tag"]], merge_config(self.config, clip.get("config_overrides")))

    @staticmethod
    def _flagged(res: dict) -> set:
        j = res["joints"]
        return {v["joint"] for v in j["verdicts"] + j["angle_verdicts"] if v["severity"] != "ok"}

    def test_committed_fixture_matches_the_generator(self) -> None:
        with open(ROOT / "fixtures" / "lesson_clips.json", "r", encoding="utf-8") as f:
            self.assertEqual(json.load(f), json.loads(json.dumps(self.dataset)))

    def test_expected_labels(self) -> None:
        for clip_id, clip in self.clips.items():
            self.assertEqual(self._score(clip_id)["passed"], clip["expected"]["passed"], clip_id)

    def test_windows_come_from_the_manifest_slice(self) -> None:
        ref = self.refs["clasp_windowed"]
        self.assertEqual(len(ref["windows"]), 1)
        w = ref["windows"][0]
        self.assertEqual(w["mask"], ["hand_shape"])
        self.assertAlmostEqual(w["start_s"], ref["beat_times"][2] - 0.2, places=4)  # rebased to the segment start
        self.assertEqual(windows_at(ref["windows"], ref["beat_times"][3]), [w])
        self.assertEqual(windows_at(ref["windows"], ref["beat_times"][0]), [])
        self.assertEqual(windows_at(ref["windows"], w["end_s"]), [])  # end is exclusive
        self.assertEqual(self.refs["clasp"]["windows"], [])

    def test_clasp_window_masks_hands_and_scales_wrists(self) -> None:
        plain = self._score("lesson_07_clasp_no_window")
        windowed = self._score("lesson_08_clasp_window_mask")
        near = self._score("lesson_09_clasp_wrist_proximity")
        self.assertTrue({"leftWrist", "rightWrist"} <= self._flagged(plain))
        self.assertEqual(plain["hands"]["masked_samples"], 0)
        self.assertLess(plain["hands"]["hand_score"], 80.0)
        self.assertEqual(windowed["hands"]["masked_samples"], 12)  # counts 3-6 x 3 samples
        self.assertEqual(windowed["hands"]["hand_score"], 100.0)
        self.assertEqual(self._flagged(windowed), set())
        # No window, but the occlusion rule sees the wrists together and widens them on every beat.
        self.assertEqual(near["hands"]["masked_samples"], 0)
        self.assertFalse({"leftWrist", "rightWrist"} & self._flagged(near))

    def test_stretched_windows_and_rate_70(self) -> None:
        stretched = lesson_package.stretch(self.refs["clasp_windowed"], 0.7)
        self.assertAlmostEqual(stretched["windows"][0]["start_s"], self.refs["clasp_windowed"]["windows"][0]["start_s"] / 0.7)
        ref = self.refs["hits_rate_70"]
        self.assertEqual(ref["speed_pct"], 70)
        self.assertAlmostEqual(ref["bpm"], 112.5 * 0.7)
        clean = self._score("lesson_10_rate70_clean")
        late = self._score("lesson_11_rate70_late")
        self.assertTrue(clean["passed"])
        self.assertEqual(clean["hits"]["status"], "available")
        self.assertGreaterEqual(clean["hits"]["hit_score"], 95.0)
        self.assertFalse(late["passed"])
        self.assertGreater(late["timing"]["mean_offset_ms"], 120.0)

    def test_velocity_factors_follow_the_reference_speed(self) -> None:
        ref = self.refs["arm_swing"]
        frames = ref["frames"]
        beat = ref["beat_times"][2]
        cfg = deep_merge(DEFAULT_TOLERANCE, {"velocity_scale": 0.5})
        pos, ang = reference_velocity_factors(frames, beat, (0.0, -1.0, 0.0), cfg)
        self.assertGreater(pos["leftWrist"], 2.0)  # ~3 rad/s swing through the beat
        self.assertLessEqual(pos["leftWrist"], cfg["velocity_max_factor"])
        self.assertAlmostEqual(pos["leftShoulder"], 1.0, delta=0.05)  # the shoulders hardly move
        self.assertIn("leftKnee", ang)
        capped = reference_velocity_factors(frames, beat, (0.0, -1.0, 0.0), dict(cfg, velocity_scale=50.0))[0]
        self.assertEqual(capped["leftWrist"], cfg["velocity_max_factor"])
        self.assertEqual(reference_velocity_factors(frames, beat, (0.0, -1.0, 0.0), dict(cfg, velocity_half_window_s=0.0)), ({}, {}))

    def test_velocity_scaling_forgives_fast_beats(self) -> None:
        off = self._score("lesson_15_velocity_off")
        on = self._score("lesson_16_velocity_scaled")
        self.assertTrue({"leftWrist", "rightWrist"} <= self._flagged(off))
        self.assertEqual(self._flagged(on), set())
        tol_off = {v["joint"]: v["tolerance"] for v in off["joints"]["verdicts"]}
        tol_on = {v["joint"]: v["tolerance"] for v in on["joints"]["verdicts"]}
        self.assertEqual(tol_off, tol_on)  # base tolerances unchanged; the per-beat error is scaled

    def test_occlusion_widens_or_masks_dropouts(self) -> None:
        off = self._score("lesson_17_occlusion_off")
        widened = self._score("lesson_18_occlusion_widened")
        masked = self._score("lesson_19_occlusion_masked")
        self.assertTrue({"leftWrist", "rightWrist"} <= self._flagged(off))
        self.assertEqual(self._flagged(widened), set())
        self.assertEqual(self._flagged(masked), set())
        err = {name: {v["joint"]: v["error"] for v in r["joints"]["verdicts"]} for name, r in
               (("off", off), ("widened", widened), ("masked", masked))}
        self.assertLess(err["widened"]["leftWrist"], err["off"]["leftWrist"])
        self.assertLess(err["masked"]["leftWrist"], err["widened"]["leftWrist"])
        self.assertEqual(err["masked"]["leftHip"], err["off"]["leftHip"])  # confident joints are untouched

    def test_new_keys_are_no_ops_on_existing_fixtures(self) -> None:
        features = generate_feature_dataset()
        ref = features["references"]["arm_hits"]
        clip = features["golden_clips"][1]
        neutral = merge_config(self.config, {"scoring_thresholds": {
            "tolerance": {"velocity_scale": 0.0, "occlusion": {"factor": 1.0, "mask": False, "wrist_distance": 0.0}},
            "retarget": {"enabled": False},
        }})
        self.assertEqual(score_attempt(clip, ref, self.config), score_attempt(clip, ref, neutral))
        self.assertEqual(score_attempt(clip, dict(ref, windows=[]), self.config), score_attempt(clip, ref, self.config))


if __name__ == "__main__":
    unittest.main()
