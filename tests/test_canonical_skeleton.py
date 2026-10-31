"""Tests for groove_eval.canonical_skeleton (MediaPipe world landmarks -> groove.canonical/1).

Swift mirror (M1, WO-1A): ios/GrooveCore/Tests/GrooveCoreTests/CanonicalSkeletonTests.swift, same fixture and
expectations; `expected_canonical` in fixtures/mediapipe_sample_frames.json is the parity target.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from groove_eval import scoring
from groove_eval.canonical_skeleton import (
    CANONICAL_BONES,
    CANONICAL_JOINTS,
    MEDIAPIPE_INDEX,
    SKELETON_ID,
    bone_lengths,
    to_canonical,
)

FIXTURE = Path(__file__).resolve().parent.parent / "fixtures" / "mediapipe_sample_frames.json"


def _standing_landmarks():
    """33 MediaPipe-style world landmarks (+y down, -z toward camera) for a person facing the camera."""
    lm = [[0.0, 0.0, 0.0] for _ in range(33)]
    lm[0] = [0.0, -0.65, -0.20]  # nose: above the hips, toward the camera
    lm[11], lm[12] = [0.18, -0.50, 0.0], [-0.18, -0.50, 0.0]  # shoulders (dancer's left is image right)
    lm[13], lm[14] = [0.22, -0.25, 0.0], [-0.22, -0.25, 0.0]
    lm[15], lm[16] = [0.20, -0.75, -0.05], [-0.25, 0.0, 0.0]  # left wrist raised above the head, right hanging
    lm[23], lm[24] = [0.11, 0.02, 0.01], [-0.11, -0.02, 0.03]  # hips, deliberately not centred on the origin
    lm[25], lm[26] = [0.11, 0.40, -0.05], [-0.11, 0.40, -0.05]
    lm[27], lm[28] = [0.11, 0.80, 0.0], [-0.11, 0.80, 0.0]
    lm[29], lm[30] = [0.11, 0.85, 0.05], [-0.11, 0.85, 0.05]
    lm[31], lm[32] = [0.11, 0.86, -0.15], [-0.11, 0.86, -0.15]  # toes point toward the camera
    vis = [0.9] * 33
    return lm, vis


def _hand(wrist_xy, spread=0.01, shift=(0.0, 0.0, 0.0)):
    world = [[shift[0] + spread * i, shift[1] - spread * i, shift[2]] for i in range(21)]
    image = [[wrist_xy[0], wrist_xy[1], 0.0]] + [[wrist_xy[0], wrist_xy[1] - 0.01 * i, 0.0] for i in range(1, 21)]
    return {"world_landmarks": world, "image_landmarks": image}


def _image_landmarks(left_wrist_xy, right_wrist_xy):
    img = [[0.5, 0.5, 0.0] for _ in range(33)]
    img[15] = [left_wrist_xy[0], left_wrist_xy[1], 0.0]
    img[16] = [right_wrist_xy[0], right_wrist_xy[1], 0.0]
    return img


class TestAxesAndSynthesizedJoints(unittest.TestCase):
    def setUp(self) -> None:
        self.lm, self.vis = _standing_landmarks()
        self.frame = to_canonical(self.lm, self.vis, t=1.25)

    def test_frame_shape(self):
        self.assertEqual(self.frame["t"], 1.25)
        self.assertEqual(tuple(self.frame["joints"]), CANONICAL_JOINTS)
        self.assertEqual(tuple(self.frame["confidences"]), CANONICAL_JOINTS)
        self.assertNotIn("hands", self.frame)
        self.assertEqual(SKELETON_ID, "groove.canonical/1")

    def test_raised_wrist_is_above_its_shoulder(self):
        j = self.frame["joints"]
        self.assertGreater(j["leftWrist"][1], j["leftShoulder"][1])
        self.assertLess(j["rightWrist"][1], j["rightShoulder"][1])
        self.assertGreater(j["nose"][1], j["centerShoulder"][1])
        self.assertLess(j["leftAnkle"][1], j["leftKnee"][1])

    def test_toward_camera_is_plus_z_and_x_is_kept(self):
        j = self.frame["joints"]
        self.assertGreater(j["nose"][2], 0.0)
        self.assertGreater(j["leftFootIndex"][2], j["leftHeel"][2])
        # x keeps MediaPipe's sign: the camera-facing dancer's left side is image right (+x).
        self.assertGreater(j["leftHip"][0], j["rightHip"][0])
        self.assertGreater(j["leftShoulder"][0], 0.0)

    def test_root_relative_and_synthesized_midpoints(self):
        j = self.frame["joints"]
        self.assertEqual(j["root"], [0.0, 0.0, 0.0])
        root = [(self.lm[23][k] + self.lm[24][k]) * 0.5 for k in range(3)]
        root = [root[0], -root[1], -root[2]]
        for name, idx in MEDIAPIPE_INDEX.items():
            raw = self.lm[idx]
            self.assertEqual(j[name], [raw[0] - root[0], -raw[1] - root[1], -raw[2] - root[2]], name)
        for k in range(3):
            self.assertAlmostEqual(j["centerShoulder"][k], (j["leftShoulder"][k] + j["rightShoulder"][k]) / 2, places=12)
            self.assertAlmostEqual(j["spine"][k], j["centerShoulder"][k] / 2, places=12)
            self.assertAlmostEqual((j["leftHip"][k] + j["rightHip"][k]) / 2, 0.0, places=12)

    def test_confidences_are_visibility_and_synthesized_take_the_min(self):
        vis = [0.9] * 33
        vis[11], vis[12], vis[23], vis[24], vis[15] = 0.7, 0.8, 0.6, 0.95, 1.4
        c = to_canonical(self.lm, vis)["confidences"]
        self.assertEqual(c["leftShoulder"], 0.7)
        self.assertEqual(c["leftWrist"], 1.0)  # clamped
        self.assertEqual(c["centerShoulder"], 0.7)
        self.assertEqual(c["root"], 0.6)
        self.assertEqual(c["spine"], 0.6)

    def test_covers_every_joint_the_scoring_engine_reads(self):
        names = set(CANONICAL_JOINTS)
        self.assertTrue(set(scoring.REQUIRED_BODY_JOINTS) <= names)
        self.assertTrue(set(scoring.REQUIRED_FOOT_JOINTS) <= names)
        for left, right in scoring.MIRROR_SWAP_PAIRS:
            self.assertIn(left, names)
            self.assertIn(right, names)

    def test_rejects_wrong_landmark_count(self):
        with self.assertRaises(ValueError):
            to_canonical(self.lm[:32], self.vis[:32])


class TestNearestWristHands(unittest.TestCase):
    def setUp(self) -> None:
        self.lm, self.vis = _standing_landmarks()
        self.img = _image_landmarks((0.60, 0.30), (0.40, 0.50))

    def test_two_hands_go_to_the_nearest_wrist_not_the_label(self):
        near_right = dict(_hand((0.41, 0.49)), handedness="Left")
        near_left = dict(_hand((0.59, 0.31), spread=0.02, shift=(1.0, 1.0, 1.0)), handedness="Right")
        f = to_canonical(self.lm, self.vis, [near_right, near_left], image_landmarks=self.img)
        self.assertEqual(sorted(f["hands"]), ["left", "right"])
        self.assertEqual(f["hands"]["left"][0], f["joints"]["leftWrist"])
        self.assertEqual(f["hands"]["right"][0], f["joints"]["rightWrist"])
        # Each hand keeps its own shape in canonical axes (y flipped): left got the spread-0.02 hand.
        lw, rw = f["joints"]["leftWrist"], f["joints"]["rightWrist"]
        self.assertAlmostEqual(f["hands"]["left"][1][0], lw[0] + 0.02, places=12)
        self.assertAlmostEqual(f["hands"]["left"][1][1], lw[1] + 0.02, places=12)
        self.assertAlmostEqual(f["hands"]["left"][1][2], lw[2], places=12)
        self.assertAlmostEqual(f["hands"]["right"][1][0], rw[0] + 0.01, places=12)
        self.assertEqual(len(f["hands"]["left"]), 21)

    def test_single_hand_goes_to_its_nearer_wrist(self):
        f = to_canonical(self.lm, self.vis, [_hand((0.42, 0.52))], image_landmarks=self.img)
        self.assertEqual(list(f["hands"]), ["right"])

    def test_merged_hands_pick_the_cheapest_pairing(self):
        # Clasp: both hand wrists sit between the pose wrists; the pairing with the smaller total distance wins.
        img = _image_landmarks((0.52, 0.40), (0.48, 0.40))
        a, b = _hand((0.47, 0.40), spread=0.01), _hand((0.53, 0.40), spread=0.03)
        f = to_canonical(self.lm, self.vis, [a, b], image_landmarks=img)
        rw, lw = f["joints"]["rightWrist"], f["joints"]["leftWrist"]
        self.assertAlmostEqual(f["hands"]["right"][1][0], rw[0] + 0.01, places=12)
        self.assertAlmostEqual(f["hands"]["left"][1][0], lw[0] + 0.03, places=12)
        f2 = to_canonical(self.lm, self.vis, [b, a], image_landmarks=img)
        self.assertEqual(f["hands"], f2["hands"])

    def test_image_aspect_scales_x_distances(self):
        img = _image_landmarks((0.70, 0.50), (0.50, 0.70))
        hand = _hand((0.50, 0.55))  # normalized: nearer the right wrist; in 720x1280 pixels: nearer the left
        self.assertEqual(list(to_canonical(self.lm, self.vis, [hand], image_landmarks=img)["hands"]), ["right"])
        portrait = to_canonical(self.lm, self.vis, [hand], image_landmarks=img, image_aspect=720 / 1280)
        self.assertEqual(list(portrait["hands"]), ["left"])

    def test_hands_need_pose_image_landmarks(self):
        with self.assertRaises(ValueError):
            to_canonical(self.lm, self.vis, [_hand((0.4, 0.5))])


class TestRetargetHook(unittest.TestCase):
    def test_bones_form_a_tree_over_every_joint(self):
        children = [c for c, _ in CANONICAL_BONES]
        self.assertEqual(sorted(children), sorted(set(CANONICAL_JOINTS) - {"root"}))
        reached = {"root"}
        for child, parent in CANONICAL_BONES:  # parents are listed before their children
            self.assertIn(parent, reached)
            reached.add(child)

    def test_bone_lengths_scale_with_the_body(self):
        lm, vis = _standing_landmarks()
        frame = to_canonical(lm, vis)
        big = to_canonical([[2 * v for v in p] for p in lm], vis)
        a, b = bone_lengths(frame), bone_lengths(big)
        self.assertEqual(set(a), {c for c, _ in CANONICAL_BONES})
        for name in a:
            self.assertAlmostEqual(b[name], 2 * a[name], places=12)


class TestRealMediaPipeFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with open(FIXTURE, "r", encoding="utf-8") as f:
            cls.doc = json.load(f)
        cls.frames = {f["frame_index"]: f for f in cls.doc["frames"]}

    def _canonical(self, idx):
        f = self.frames[idx]
        return to_canonical(f["world_landmarks"], f["visibility"], t=f["t"])

    def test_fixture_provenance(self):
        self.assertEqual(self.doc["skeleton"], SKELETON_ID)
        ext = self.doc["extractor"]
        self.assertEqual(ext["pose_model_sha256"], "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1")
        self.assertEqual((ext["running_mode"], ext["num_poses"]), ("VIDEO", 1))
        self.assertGreaterEqual(len(self.doc["frames"]), 10)

    def test_mapper_reproduces_expected_canonical_exactly(self):
        for idx, f in self.frames.items():
            self.assertEqual(self._canonical(idx), f["expected_canonical"], f"frame {idx}")

    def test_crown_clasp_wrists_above_shoulders(self):
        j = self._canonical(390)["joints"]  # 13.0 s, overhead crown clasp
        self.assertGreater(j["leftWrist"][1], j["leftShoulder"][1] + 0.15)
        self.assertGreater(j["rightWrist"][1], j["rightShoulder"][1] + 0.15)

    def test_first_downbeat_right_hand_by_the_ear(self):
        j = self._canonical(16)["joints"]  # 0.53 s: right hand raised by the right ear, left hand on the hip
        self.assertGreater(j["rightWrist"][1], j["rightShoulder"][1])
        self.assertLess(j["leftWrist"][1], j["leftShoulder"][1])

    def test_dancer_faces_the_camera(self):
        for idx in self.frames:
            j = self._canonical(idx)["joints"]
            self.assertGreater(j["nose"][2], 0.0, idx)
            self.assertGreater(j["leftFootIndex"][2], j["leftHeel"][2], idx)
            self.assertGreater(j["leftHip"][0], j["rightHip"][0], idx)
            self.assertGreater(j["nose"][1], j["root"][1], idx)


if __name__ == "__main__":
    unittest.main()
