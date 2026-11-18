"""Tests for bone-length retargeting (groove_eval/retarget.py) and its wiring into score_attempt (`retarget.enabled`).

Swift mirror: ios/GrooveCore/Tests/GrooveCoreTests/RetargetTests.swift (same vectors and expectations).
"""

from __future__ import annotations

import math
import unittest

from groove_eval import retarget
from groove_eval.canonical_skeleton import CANONICAL_BONES, bone_lengths
from groove_eval.generate_lesson_clips import generate_lesson_dataset
from groove_eval.scoring import load_config, merge_config, score_attempt


def _frame(scale: float = 1.0, arm: float = 1.0) -> dict:
    """A small canonical frame: root at origin, arms out to the sides."""
    joints = {
        "root": [0.0, 0.0, 0.0],
        "spine": [0.0, 0.25 * scale, 0.0],
        "centerShoulder": [0.0, 0.5 * scale, 0.0],
        "leftShoulder": [-0.18 * scale, 0.5 * scale, 0.0],
        "leftElbow": [-(0.18 * scale + 0.28 * arm), 0.5 * scale, 0.0],
        "leftWrist": [-(0.18 * scale + 0.54 * arm), 0.5 * scale + 0.0, 0.0],
        "rightShoulder": [0.18 * scale, 0.5 * scale, 0.0],
        "rightElbow": [0.18 * scale + 0.28 * arm * 0.6, 0.5 * scale + 0.28 * arm * 0.8, 0.0],
        "rightWrist": [0.18 * scale + 0.28 * arm * 0.6, 0.5 * scale + 0.28 * arm * 0.8 + 0.26 * arm, 0.0],
        "leftHip": [-0.11 * scale, 0.0, 0.0],
        "leftKnee": [-0.11 * scale, -0.42 * scale, 0.05 * scale],
        "leftAnkle": [-0.11 * scale, -0.82 * scale, 0.0],
        "rightHip": [0.11 * scale, 0.0, 0.0],
        "rightKnee": [0.11 * scale, -0.42 * scale, 0.05 * scale],
        "rightAnkle": [0.11 * scale, -0.82 * scale, 0.0],
    }
    return {"t": 0.0, "joints": joints, "confidences": {k: 0.9 for k in joints}}


def _unit(a, b):
    d = [b[k] - a[k] for k in range(3)]
    n = math.sqrt(sum(x * x for x in d))
    return [x / n for x in d]


class TestRetargetMath(unittest.TestCase):
    def test_mirror_name(self) -> None:
        self.assertEqual(retarget.mirror_name("leftWrist"), "rightWrist")
        self.assertEqual(retarget.mirror_name("rightFootIndex"), "leftFootIndex")
        self.assertEqual(retarget.mirror_name("spine"), "spine")

    def test_median_bone_lengths(self) -> None:
        frames = [_frame(1.0), _frame(1.2), _frame(1.1)]
        lengths = retarget.median_bone_lengths(frames)
        self.assertAlmostEqual(lengths["spine"], 0.25 * 1.1, places=12)
        self.assertAlmostEqual(lengths["leftKnee"], bone_lengths(_frame(1.1))["leftKnee"], places=12)
        even = retarget.median_bone_lengths([_frame(1.0), _frame(1.2)])
        self.assertAlmostEqual(even["spine"], 0.25 * 1.1, places=12)
        self.assertNotIn("nose", lengths)

    def test_retarget_keeps_directions_and_takes_learner_lengths(self) -> None:
        teacher = _frame(1.0, arm=1.0)
        learner_lengths = bone_lengths(_frame(1.15, arm=1.4))
        out = retarget.retarget_frame(teacher, learner_lengths)
        self.assertEqual(out["joints"]["root"], [0.0, 0.0, 0.0])
        got = bone_lengths(out)
        for child, parent in CANONICAL_BONES:
            if child not in learner_lengths:
                continue
            self.assertAlmostEqual(got[child], learner_lengths[child], places=12, msg=child)
            want = _unit(teacher["joints"][parent], teacher["joints"][child])
            have = _unit(out["joints"][parent], out["joints"][child])
            for k in range(3):
                self.assertAlmostEqual(have[k], want[k], places=12, msg=child)
        self.assertEqual(out["confidences"], teacher["confidences"])

    def test_missing_lengths_keep_teacher_bones_and_hands_follow_the_wrist(self) -> None:
        teacher = _frame(1.0)
        teacher["joints"]["nose"] = [0.0, 0.7, 0.05]
        teacher["hands"] = {"left": [[p[0] + 0.01 * i, p[1], p[2]] for i, p in enumerate([teacher["joints"]["leftWrist"]] * 21)]}
        lengths = {"leftElbow": 0.5, "leftWrist": 0.5}
        out = retarget.retarget_frame(teacher, lengths)
        j = out["joints"]
        self.assertEqual(j["nose"], teacher["joints"]["nose"])  # no length: same offset from its walked parent
        self.assertAlmostEqual(math.dist(j["leftShoulder"], j["leftElbow"]), 0.5, places=12)
        shift = [j["leftWrist"][k] - teacher["joints"]["leftWrist"][k] for k in range(3)]
        for got, was in zip(out["hands"]["left"], teacher["hands"]["left"]):
            for k in range(3):
                self.assertAlmostEqual(got[k], was[k] + shift[k], places=12)
        self.assertEqual(out["hands"]["left"][0], j["leftWrist"])

    def test_learner_lengths_prefer_calibration_and_swap_when_mirrored(self) -> None:
        take = {"frames": [_frame(1.0)], "mirrored": False}
        calibrated = dict(take, calibration_frames=[_frame(1.3)])
        self.assertAlmostEqual(retarget.learner_bone_lengths(take)["spine"], 0.25, places=12)
        self.assertAlmostEqual(retarget.learner_bone_lengths(calibrated)["spine"], 0.325, places=12)
        self.assertEqual(retarget.learner_bone_lengths(dict(take, calibration_frames=[]))["spine"], 0.25)
        plain = retarget.learner_bone_lengths(take)
        mirrored = retarget.learner_bone_lengths(dict(take, mirrored=True))
        self.assertEqual(mirrored["leftElbow"], plain["rightElbow"])
        self.assertEqual(mirrored["rightWrist"], plain["leftWrist"])
        self.assertEqual(mirrored["spine"], plain["spine"])

    def test_frame_without_root_is_unchanged(self) -> None:
        frame = {"t": 0.0, "joints": {"leftHip": [0.1, 0.0, 0.0]}}
        self.assertEqual(retarget.retarget_frame(frame, {"leftHip": 1.0}), frame)


class TestRetargetScoring(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        ds = generate_lesson_dataset()
        cls.refs = ds["references"]
        cls.clips = {c["clip_id"]: c for c in ds["golden_clips"]}

    def _score(self, clip_id: str) -> dict:
        clip = self.clips[clip_id]
        return score_attempt(clip, self.refs[clip["move_tag"]], merge_config(self.config, clip.get("config_overrides")))

    def test_long_armed_learner_needs_retarget(self) -> None:
        off = self._score("lesson_12_retarget_off")
        on = self._score("lesson_13_retarget_on")
        calibrated = self._score("lesson_14_retarget_calibration")
        self.assertFalse(off["retargeted"])
        self.assertTrue(on["retargeted"] and calibrated["retargeted"])
        flagged = {v["joint"] for v in off["joints"]["verdicts"] if v["severity"] != "ok"}
        self.assertTrue({"leftWrist", "rightWrist"} <= flagged)
        self.assertTrue(off["joints"]["top_hint"].startswith("move "))
        for res in (on, calibrated):
            self.assertEqual(res["joints"]["counts"]["warn"] + res["joints"]["counts"]["off"], 0)
        # Angles are invariant to bone lengths: the shape score passes either way (see the work report).
        self.assertTrue(off["passed"] and on["passed"] and calibrated["passed"])
        self.assertLess(abs(off["shape"]["shape_score"] - on["shape"]["shape_score"]), 1.0)

    def test_retarget_off_by_default_changes_nothing(self) -> None:
        clip = self.clips["lesson_12_retarget_off"]
        ref = self.refs["retarget_short"]
        explicit_off = merge_config(self.config, {"scoring_thresholds": {"retarget": {"enabled": False}}})
        self.assertEqual(score_attempt(clip, ref, self.config), score_attempt(clip, ref, explicit_off))


if __name__ == "__main__":
    unittest.main()
