"""Unit tests for the One Euro filter; vectors are shared with OneEuroFilterTests.swift."""

from __future__ import annotations

import unittest

from groove_eval.one_euro import OneEuroFilter, OneEuroFilter3D, OneEuroLandmarkBank

TIMES = [0.0, 0.033, 0.066, 0.1, 0.1, 0.133, 0.166, 0.2]
INPUTS = [0.0, 0.5, 0.4, 1.5, 9.0, 1.6, 1.62, 1.58]
EXPECTED = [
    0.0, 0.32562549582249173, 0.3737209722701977, 1.322236404352722,
    1.322236404352722, 1.555425022804561, 1.6084372264441136, 1.5858718784763046,
]


class OneEuroTests(unittest.TestCase):
    def test_scalar_matches_reference_vectors(self) -> None:
        f = OneEuroFilter()
        for x, t, e in zip(INPUTS, TIMES, EXPECTED):
            self.assertAlmostEqual(f.filter(x, t), e, delta=1e-9)

    def test_reset_restarts_from_first_sample(self) -> None:
        f = OneEuroFilter()
        f.filter(5.0, 0.0)
        f.filter(6.0, 0.1)
        f.reset()
        self.assertEqual(f.filter(-3.0, 0.0), -3.0)

    def test_landmark_bank_independent_joints(self) -> None:
        bank = OneEuroLandmarkBank()
        scalar = OneEuroFilter()
        for x, t in zip(INPUTS, TIMES):
            out = bank.filter({"a": [x, 1.0, 2.0], "b": [0.0, 0.0, 0.0]}, t)
            self.assertAlmostEqual(out["a"][0], scalar.filter(x, t), delta=1e-12)
            self.assertAlmostEqual(out["a"][1], 1.0, delta=1e-12)
            self.assertEqual(out["b"], [0.0, 0.0, 0.0])

    def test_3d_filter_matches_scalar_per_axis(self) -> None:
        f3 = OneEuroFilter3D()
        fx = OneEuroFilter()
        for x, t in zip(INPUTS, TIMES):
            self.assertAlmostEqual(f3.filter([x, 0.0, 0.0], t)[0], fx.filter(x, t), delta=1e-12)


if __name__ == "__main__":
    unittest.main()
