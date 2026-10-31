"""Tests for groove_eval.lesson_package: manifest schema + cross-field rules, slice/stretch, adaptive speed.

Swift mirror (M1, WO-1A): ios/GrooveCore/Tests/GrooveCoreTests/LessonPackageTests.swift, same manifest, slice
boundaries and `next_rate` vectors.
"""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from groove_eval.generate_feature_clips import generate_feature_dataset
from groove_eval.lesson_package import (
    DEFAULT_ADAPTIVE_SPEED,
    LessonPackageError,
    load_manifest,
    load_schema,
    next_rate,
    quantize_rate,
    segment_config,
    segment_policy,
    slice_reference,
    stretch,
    teaching_sequence,
    validate_manifest,
    validate_schema,
)
from groove_eval.scoring import load_config, score_attempt

try:
    import jsonschema
except ImportError:  # linux-ci installs nothing beyond the stdlib
    jsonschema = None

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT / "fixtures" / "lessons" / "example_manifest.json"


def _example():
    with open(EXAMPLE, "r", encoding="utf-8") as f:
        return json.load(f)


def _reference_clip(duration_s=16.33, fps=30.0):
    """A full-lesson reference on the media timeline (joint values are irrelevant to slicing)."""
    n = int(round(duration_s * fps))
    frames = [{"t": round(i / fps, 6), "joints": {"root": [0.0, 0.0, 0.0]}, "confidences": {"root": 1.0}} for i in range(n)]
    return {"clip_id": "img4941", "move_tag": "lesson", "bpm": 112.5, "beat_times": [], "frames": frames}


class TestManifestValidation(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        cls.schema = load_schema()

    def _errors(self, mutate):
        m = _example()
        mutate(m)
        return validate_manifest(m, self.config, self.schema)

    def assertRejected(self, mutate, fragment):
        errors = self._errors(mutate)
        self.assertTrue(any(fragment in e for e in errors), f"{fragment!r} not in {errors}")

    def test_example_manifest_is_valid(self):
        self.assertEqual(validate_manifest(_example(), self.config, self.schema), [])
        m = load_manifest(EXAMPLE)
        self.assertEqual(m["schema"], "groove.lesson/1")

    @unittest.skipIf(jsonschema is None, "jsonschema not installed")
    def test_example_manifest_passes_reference_jsonschema(self):
        jsonschema.Draft202012Validator.check_schema(self.schema)
        jsonschema.Draft202012Validator(self.schema).validate(_example())

    def test_structural_rules(self):
        self.assertRejected(lambda m: m.update(schema="groove.lesson/2"), "$.schema")
        self.assertRejected(lambda m: m.update(package_version=0), "$.package_version")
        self.assertRejected(lambda m: m.update(package_version=True), "$.package_version")
        self.assertRejected(lambda m: m["extractor"].update(pose_model_sha256="5134A3"), "pose_model_sha256")
        self.assertRejected(lambda m: m["extractor"].update(num_poses=2), "num_poses")
        self.assertRejected(lambda m: m.update(surprise=1), "$.surprise: unexpected field")
        self.assertRejected(lambda m: m["practice"].pop("adaptive_speed"), "adaptive_speed")
        self.assertRejected(lambda m: m["practice"].update(speeds=[0.75, 1.0]), "speeds: unexpected field")
        self.assertRejected(lambda m: m["windows"][0]["tolerance_scale"].update(leftPinky=2.0), "property name")
        self.assertRejected(lambda m: m["files"].update({"video.mp4": "abc"}), "video.mp4")

    @unittest.skipIf(jsonschema is None, "jsonschema not installed")
    def test_structural_rejects_agree_with_jsonschema(self):
        validator = jsonschema.Draft202012Validator(self.schema)
        mutations = [
            lambda m: m.update(package_version=0),
            lambda m: m.update(package_version=True),
            lambda m: m["extractor"].update(num_poses=2),
            lambda m: m.update(surprise=1),
            lambda m: m["practice"]["adaptive_speed"].update(min_rate=0.4),
            lambda m: m["windows"][0]["tolerance_scale"].update(leftPinky=2.0),
            lambda m: m["beat_grid"]["beats"][0].update(count=9),
        ]
        for mutate in mutations:
            m = _example()
            mutate(m)
            self.assertNotEqual(validate_schema(m, self.schema), [])
            self.assertFalse(validator.is_valid(m))

    def test_unsupported_schema_keyword_is_an_error_not_a_silent_pass(self):
        with self.assertRaises(LessonPackageError):
            validate_schema({}, {"type": "object", "oneOf": []})

    def test_segment_boundaries_must_sit_on_a_beat(self):
        self.assertRejected(lambda m: m["segments"][3].update(end_s=14.80), "$.segments[3].end_s")
        self.assertEqual(self._errors(lambda m: m["segments"][0].update(start_s=0.565)), [])  # 35 ms off: ok

    def test_cross_field_rules(self):
        self.assertRejected(lambda m: m["beat_grid"]["beats"][2].update(t=0.9), "strictly increasing")
        self.assertRejected(lambda m: m["windows"][1].update(end_s=17.0), "$.windows[1]")
        self.assertRejected(lambda m: m["segments"][0].update(end_s=0.53), "$.segments[0]")
        self.assertRejected(lambda m: m["segments"][1].update(id="A"), "duplicate segment id")
        self.assertRejected(lambda m: m["segments"][4].update(teach_order=7), "teach_order")
        self.assertRejected(lambda m: m["files"].pop("reference_pose.json"), "reference_pose.json")
        self.assertRejected(lambda m: m["files"].pop("poster.jpg"), "poster.jpg")
        self.assertRejected(lambda m: m["files"].update({"manifest.json": "0" * 64}), "manifest.json")

    def test_config_override_keys(self):
        def lesson(over):
            return lambda m: m.update(config_overrides=over)

        self.assertRejected(lesson({"scoring_thresholds": {"shape": {"armweight": 0.3}}}), "armweight")
        self.assertRejected(lesson({"scoring_thresholds": {"hits": {"enabled": 1}}}), "hits.enabled")
        self.assertRejected(lesson({"scoring_thresholds": {"timing": {"perfect_max_ms": "60"}}}), "perfect_max_ms")
        self.assertRejected(lesson({"scoring_thresholds": {"timing": 5}}), "config_overrides must be an object")
        self.assertRejected(lesson({"scoring_thresholds": {"shape": {"arm_weight": 1.5}}}), "arm_weight")
        self.assertRejected(
            lambda m: m["segments"][2]["config_overrides"]["scoring_thresholds"]["gate"].update(timing_source="beats"),
            "timing_source",
        )
        self.assertEqual(self._errors(lesson({"scoring_thresholds": {"timing": {"perfect_max_ms": 70}}})), [])

    def test_adaptive_speed_policy_rules(self):
        def policy(**kw):
            return lambda m: m["practice"]["adaptive_speed"].update(**kw)

        self.assertRejected(policy(start_rate=0.55), "start_rate")
        self.assertRejected(policy(unlock_next_at_rate=0.55), "unlock_next_at_rate")
        self.assertRejected(policy(min_rate=0.4), "min_rate")
        self.assertRejected(policy(max_rate=1.25), "max_rate")
        self.assertRejected(policy(promote_after=0), "promote_after")
        self.assertRejected(
            lambda m: m["segments"][4].update(adaptive_speed=dict(DEFAULT_ADAPTIVE_SPEED, start_rate=0.95, max_rate=0.9)),
            "$.segments[4].adaptive_speed",
        )


class TestLessonLookups(unittest.TestCase):
    def setUp(self) -> None:
        self.m = _example()
        self.config = load_config()

    def test_teaching_order_is_a_to_d_then_full(self):
        self.assertEqual(teaching_sequence(self.m), ["A", "B", "C", "D", "full"])

    def test_example_ships_the_default_policy(self):
        self.assertEqual(self.m["practice"]["adaptive_speed"], DEFAULT_ADAPTIVE_SPEED)
        self.assertEqual(segment_policy(self.m, "C"), DEFAULT_ADAPTIVE_SPEED)
        self.m["segments"][4]["adaptive_speed"] = dict(DEFAULT_ADAPTIVE_SPEED, start_rate=0.8)
        self.assertEqual(segment_policy(self.m, "full")["start_rate"], 0.8)

    def test_segment_config_merge_order(self):
        before = copy.deepcopy(self.config)
        c = segment_config(self.config, self.m, "C")
        self.assertEqual(self.config, before)  # inputs untouched
        st = c["scoring_thresholds"]
        self.assertEqual(st["gate"]["timing_source"], "hits")
        self.assertEqual(st["gate"]["min_good_or_better_beat_ratio"], 0.80)
        self.assertEqual(st["shape"]["arm_weight"], 0.35)
        self.assertEqual(st["shape"]["pass_min_score"], 70.0)
        self.assertEqual(st["groove"]["pass_min_score"], 0)
        self.assertNotIn("timing_source", segment_config(self.config, self.m, "A")["scoring_thresholds"]["gate"])
        self.m["segments"][2]["config_overrides"]["scoring_thresholds"]["shape"] = {"arm_weight": 0.5}
        self.assertEqual(segment_config(self.config, self.m, "C")["scoring_thresholds"]["shape"]["arm_weight"], 0.5)

    def test_unknown_segment(self):
        with self.assertRaises(LessonPackageError):
            segment_config(self.config, self.m, "Z")


class TestSliceAndStretch(unittest.TestCase):
    def setUp(self) -> None:
        self.m = _example()
        self.ref = _reference_clip()

    def test_slice_c_boundaries(self):
        s = slice_reference(self.ref, self.m, "C")
        # C = 6.40-9.07 s: beats 6.397 .. 8.53 (grid indices 11..15); 9.063 opens D and is not graded here.
        self.assertEqual(len(s["beat_times"]), 5)
        self.assertAlmostEqual(s["beat_times"][0], 6.397 - 6.40, places=9)
        self.assertAlmostEqual(s["beat_times"][-1], 8.53 - 6.40, places=9)
        pad = 0.5 * 60.0 / 112.5
        ts = [f["t"] for f in s["frames"]]
        self.assertGreaterEqual(ts[0], -pad - 1e-9)
        self.assertLessEqual(ts[-1], 9.07 - 6.40 + pad + 1e-9)
        self.assertEqual(len(s["frames"]), sum(1 for f in self.ref["frames"] if 6.40 - pad <= f["t"] <= 9.07 + pad))
        self.assertEqual((s["clip_id"], s["move_tag"], s["bpm"], s["speed_pct"]), ("img4941-routine/C", "C", 112.5, 100))
        self.assertEqual((s["segment_start_s"], s["segment_end_s"], s["mirrored"]), (6.40, 9.07, False))
        self.assertEqual(s["windows"], [])

    def test_slice_beat_counts_and_windows(self):
        counts = {sid: len(slice_reference(self.ref, self.m, sid)["beat_times"]) for sid in teaching_sequence(self.m)}
        self.assertEqual(counts, {"A": 8, "B": 3, "C": 5, "D": 11, "full": 27})
        b = slice_reference(self.ref, self.m, "B")
        self.assertEqual(len(b["windows"]), 1)
        self.assertAlmostEqual(b["windows"][0]["start_s"], 0.0, places=9)
        self.assertAlmostEqual(b["windows"][0]["end_s"], 5.87 - 4.80, places=9)
        self.assertEqual(b["windows"][0]["mask"], ["hand_shape"])
        self.assertEqual(len(slice_reference(self.ref, self.m, "full")["windows"]), 2)

    def test_stretch_maps_to_wall_clock(self):
        s = slice_reference(self.ref, self.m, "C")
        st = stretch(s, 0.7, DEFAULT_ADAPTIVE_SPEED)
        self.assertEqual((st["bpm"], st["speed_pct"], st["rate"]), (112.5 * 0.7, 70, 0.7))
        for a, b in zip(s["frames"], st["frames"]):
            self.assertEqual(b["t"], a["t"] / 0.7)
            self.assertIs(a["joints"], b["joints"])
        self.assertEqual(st["beat_times"], [b / 0.7 for b in s["beat_times"]])
        media = [f["t"] for f in self.ref["frames"] if f["t"] >= 6.40 - 0.5 * 60.0 / 112.5]
        self.assertEqual([f["t"] for f in s["frames"]][:3], [t - 6.40 for t in media[:3]])
        same = stretch(s, 1.0)
        self.assertEqual(same["frames"], s["frames"])
        self.assertEqual((same["bpm"], same["speed_pct"]), (112.5, 100))

    def test_stretch_accepts_every_rate_in_the_policy_range(self):
        s = slice_reference(self.ref, self.m, "B")
        for pct in range(60, 101):
            st = stretch(s, pct / 100, DEFAULT_ADAPTIVE_SPEED)
            self.assertEqual(st["speed_pct"], pct)
        self.assertEqual(stretch(s, 0.5)["speed_pct"], 50)
        for bad, policy in ((0.55, DEFAULT_ADAPTIVE_SPEED), (0.45, None), (1.05, None), (0.0, None)):
            with self.assertRaises(LessonPackageError):
                stretch(s, bad, policy)

    def test_stretched_slice_scores_like_the_original(self):
        """A sliced + stretched reference scored against itself at 0.7x passes with ~0 ms offset (spec §2.4)."""
        ref = generate_feature_dataset()["references"]["arm_hits"]  # 110 BPM, beats from 0.5 s
        m = _example()
        period = 60.0 / 110.0
        m["video"]["duration_s"] = 4.9
        m["beat_grid"].update(bpm=110.0, anchor_s=0.5, beats=[
            {"t": round(0.5 + k * period, 5), "phrase": 1, "count": k % 8 + 1} for k in range(9)])
        m["segments"] = [{"id": "S", "title": "Hits", "start_s": 0.5, "end_s": round(0.5 + 8 * period, 5), "teach_order": 1}]
        m["windows"] = []
        self.assertEqual(validate_manifest(m), [])
        sliced = slice_reference(ref, m, "S")
        self.assertEqual(len(sliced["beat_times"]), 8)
        config = load_config()
        for rate in (0.6, 0.7, 0.85, 1.0):
            clip = stretch(sliced, rate, DEFAULT_ADAPTIVE_SPEED)
            res = score_attempt(clip, clip, config)
            self.assertTrue(res["passed"], (rate, res["timing"]))
            self.assertEqual(res["between_rep_digest"]["speed_pct"], int(round(rate * 100)))
            self.assertLess(abs(res["timing"]["mean_offset_ms"]), 1.0)
            self.assertGreaterEqual(res["shape"]["shape_score"], 99.0)


class TestAdaptiveSpeed(unittest.TestCase):
    P = DEFAULT_ADAPTIVE_SPEED

    def run_takes(self, passes, policy=None, rate=None):
        return next_rate(policy or self.P, [{"passed": p} if rate is None else {"passed": p, "rate": rate} for p in passes])

    def test_fresh_segment_starts_slow(self):
        self.assertEqual(next_rate(self.P, []), (0.7, False))

    def test_promotes_after_two_passes(self):
        self.assertEqual(self.run_takes([True]), (0.7, False))
        self.assertEqual(self.run_takes([True, True]), (0.8, False))
        self.assertEqual(self.run_takes([True, True, True]), (0.8, True))  # a pass at 0.8 unlocks the next segment
        self.assertEqual(self.run_takes([True] * 6), (1.0, True))
        self.assertEqual(self.run_takes([True] * 20), (1.0, True))  # clamped at max_rate

    def test_rates_stay_on_the_grid(self):
        rate, _ = self.run_takes([True, True])
        self.assertEqual(rate, 0.8)  # not 0.7999999999999999
        self.assertEqual(quantize_rate(0.7 + 0.1), 0.8)
        self.assertEqual(quantize_rate(0.65), 0.65)
        self.assertEqual(quantize_rate(0.125), 0.13)

    def test_demotes_after_two_fails_down_to_min(self):
        self.assertEqual(self.run_takes([False]), (0.7, False))
        self.assertEqual(self.run_takes([False, False]), (0.65, False))
        self.assertEqual(self.run_takes([False] * 4), (0.6, False))
        self.assertEqual(self.run_takes([False] * 10), (0.6, False))

    def test_streaks_must_be_consecutive(self):
        self.assertEqual(self.run_takes([True, False, True, False, True, False]), (0.7, False))
        self.assertEqual(self.run_takes([True, True, False, True, True]), (0.9, True))

    def test_unlock_is_sticky(self):
        self.assertEqual(self.run_takes([True, True, True, False, False, False, False]), (0.7, True))

    def test_take_at_another_rate_moves_the_ladder_there(self):
        # Learner chose 1.0x and passed: unlocked, and the next offer stays at 1.0x.
        self.assertEqual(next_rate(self.P, [{"passed": True, "rate": 1.0}]), (1.0, True))
        # Two fails at a manual 0.9x step down from 0.9x, not from the 0.7x start.
        self.assertEqual(next_rate(self.P, [{"passed": False, "rate": 0.9}, {"passed": False, "rate": 0.9}]), (0.85, False))
        # A pass at 0.7 followed by one at 0.8 is not a streak: the rate change restarts it.
        self.assertEqual(next_rate(self.P, [{"passed": True, "rate": 0.7}, {"passed": True, "rate": 0.8}]), (0.8, True))
        # Out-of-policy take rates are clamped.
        self.assertEqual(next_rate(self.P, [{"passed": False, "rate": 0.3}]), (0.6, False))

    def test_custom_policy(self):
        p = dict(self.P, min_rate=0.5, start_rate=0.5, step_up=0.25, promote_after=1, demote_after=3, unlock_next_at_rate=1.0)
        self.assertEqual(self.run_takes([True], p), (0.75, False))
        self.assertEqual(self.run_takes([True, True], p), (1.0, False))
        self.assertEqual(self.run_takes([True, True, True], p), (1.0, True))
        self.assertEqual(self.run_takes([True, False, False, False], p), (0.7, False))

    def test_invalid_policy_raises(self):
        for bad in (dict(self.P, start_rate=0.5), dict(self.P, max_rate=1.2), dict(self.P, promote_after=0)):
            with self.assertRaises(LessonPackageError):
                next_rate(bad, [])
        with self.assertRaises(LessonPackageError):
            next_rate({k: v for k, v in self.P.items() if k != "step_up"}, [])


if __name__ == "__main__":
    unittest.main()
