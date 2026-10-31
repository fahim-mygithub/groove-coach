"""Unit tests for settle-after-move segmentation; vectors mirror MoveSegmenterTests.swift."""

from __future__ import annotations

import unittest

from groove_eval.segmentation import detect_hits, motion_energy, pair_hits_to_beats


def _clamp(v: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, v))


def _frames():
    out = []
    for i in range(80):
        x = 0.2 * (_clamp(i, 10, 20) - 10) + 0.3 * (_clamp(i, 40, 45) - 40)
        out.append({"t": i / 30.0, "joints": {"root": [0, 0, 0], "centerShoulder": [0, 2, 0], "rightWrist": [x, 1, 0]}})
    return out


class TestMoveSegmenter(unittest.TestCase):
    def test_motion_energy_is_torso_normalised(self):
        e = motion_energy(_frames())
        self.assertAlmostEqual(e[12], 1.9999999999999996, delta=1e-9)
        self.assertAlmostEqual(e[25], 0.0, delta=1e-9)

    def test_detects_two_hits(self):
        hits = detect_hits(_frames())
        self.assertEqual(len(hits), 2)
        self.assertAlmostEqual(hits[0]["timestamp"], 0.7666666666666667, delta=1e-9)
        self.assertAlmostEqual(hits[0]["peakSpeed"], 3.0000000000000013, delta=1e-9)
        self.assertAlmostEqual(hits[0]["settleDuration"], 0.1333333333333333, delta=1e-9)
        self.assertAlmostEqual(hits[1]["timestamp"], 1.6, delta=1e-9)
        self.assertAlmostEqual(hits[1]["peakSpeed"], 4.500000000000008, delta=1e-9)

    def test_no_hit_while_still_moving(self):
        self.assertEqual(detect_hits(_frames()[:18]), [])

    def test_pairs_nearest_beat_within_tolerance(self):
        pairs = pair_hits_to_beats(detect_hits(_frames()), [0.5, 0.7, 1.0, 1.65])
        self.assertEqual(len(pairs), 2)
        self.assertAlmostEqual(pairs[0]["beatTimestamp"], 0.7, delta=1e-9)
        self.assertAlmostEqual(pairs[0]["offsetMs"], 66.66666666666676, delta=1e-9)
        self.assertAlmostEqual(pairs[1]["beatTimestamp"], 1.65, delta=1e-9)
        self.assertAlmostEqual(pairs[1]["offsetMs"], -49.99999999999982, delta=1e-9)

    def test_beat_outside_tolerance_is_unmatched(self):
        self.assertEqual(pair_hits_to_beats(detect_hits(_frames()), [0.2, 1.2]), [])


if __name__ == "__main__":
    unittest.main()
