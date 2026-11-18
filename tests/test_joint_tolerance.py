"""Parity vectors for groove_eval.joint_tolerance (same inputs/outputs as JointToleranceTests.swift)."""

from __future__ import annotations

import unittest

from groove_eval.joint_tolerance import angle_tolerances, evaluate, evaluate_angles, position_tolerances


class TestJointTolerance(unittest.TestCase):
    def test_position_tolerances_from_variance(self):
        refs = [
            {"leftWrist": [0, 0, 0], "root": [0, 0, 0], "spine": [0, 0, 0]},
            {"leftWrist": [0.1, 0, 0], "root": [0, 0, 0], "spine": [2, 0, 0]},
        ]
        tol = position_tolerances(refs)
        self.assertAlmostEqual(tol["leftWrist"], 0.1, delta=1e-9)
        self.assertAlmostEqual(tol["root"], 0.03, delta=1e-9)
        self.assertAlmostEqual(tol["spine"], 0.25, delta=1e-9)

    def test_verdicts_and_hints(self):
        ref = {"leftWrist": [0, 1, 0], "rightWrist": [0, 1, 0], "root": [0, 0, 0], "leftAnkle": [0, 0, 0]}
        learner = {"leftWrist": [0, 0.95, 0], "rightWrist": [0, 0.85, 0], "root": [0, 0, 0], "leftAnkle": [0.5, 0, 0]}
        tols = {"leftWrist": 0.1, "rightWrist": 0.1, "root": 0.1, "leftAnkle": 0.1}
        v = evaluate(learner, ref, tols)
        by = {x["joint"]: x for x in v}
        self.assertEqual(by["leftWrist"]["severity"], "ok")
        self.assertIsNone(by["leftWrist"]["hint"])
        self.assertAlmostEqual(by["leftWrist"]["error"], 0.05, delta=1e-9)
        self.assertEqual(by["rightWrist"]["severity"], "warn")
        self.assertEqual(by["rightWrist"]["hint"], "raise right wrist")
        self.assertAlmostEqual(by["rightWrist"]["direction"][1], 1.0, delta=1e-9)
        self.assertEqual(by["leftAnkle"]["severity"], "off")
        self.assertEqual(by["leftAnkle"]["hint"], "move left ankle left")
        self.assertEqual([x["joint"] for x in v], ["leftAnkle", "leftWrist", "rightWrist", "root"])

    def test_angle_tolerance_and_verdict(self):
        straight = {"leftHip": [0, 1, 0], "leftKnee": [0, 0, 0], "leftAnkle": [0, -1, 0]}
        bent = {"leftHip": [0, 1, 0], "leftKnee": [0, 0, 0], "leftAnkle": [1, 0, 0]}
        tol = angle_tolerances([straight, bent])
        self.assertAlmostEqual(tol["leftKnee"], 45.0, delta=1e-9)
        v = evaluate_angles(bent, straight, {"leftKnee": 10.0})
        self.assertEqual(len(v), 1)
        self.assertAlmostEqual(v[0]["error"], 90.0, delta=1e-9)
        self.assertEqual(v[0]["severity"], "off")
        self.assertEqual(v[0]["hint"], "open left knee")


if __name__ == "__main__":
    unittest.main()
