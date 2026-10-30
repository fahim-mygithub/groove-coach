"""Tests for the wave-2 scoring components: One Euro smoothing, hit timing, joint verdicts and hand styling.

Swift mirror: ios/GrooveCore/Tests/GrooveCoreTests/ScoringFeaturesTests.swift (same fixtures and expectations).
"""

from __future__ import annotations

import copy
import unittest

from groove_eval.generate_feature_clips import generate_feature_dataset
from groove_eval.generate_golden_clips import generate_golden_dataset
from groove_eval.scoring import (
    compute_joint_tolerances,
    load_config,
    score_attempt,
    smooth_frames,
    validate_against_schema,
)


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


if __name__ == "__main__":
    unittest.main()
