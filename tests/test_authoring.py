"""CI-safe unit tests for the Groove Coach authoring pipeline (spec §2.1, §5 V1, WO-1C).

Tests run on synthetic frames and contracts; linux-ci has no mediapipe or ffmpeg, so extraction
and transcoding steps are skipped or mocked when those tools are missing.
"""

from __future__ import annotations

import copy
import json
import math
import shutil
import unittest
from pathlib import Path
from typing import Any, Dict, List

from authoring.beat_grid import (
    BEAT_THIS_LICENSE,
    build_beat_grid,
    propose_beat_grid,
)
from authoring.build_package import assemble_manifest
from authoring.extract_pose import (
    DEFAULT_SMOOTHING_PARAMS,
    HAND_MODEL_SHA256,
    POSE_MODEL_SHA256,
    round_frame_coordinates,
    smooth_canonical_frames,
)
from groove_eval.canonical_skeleton import CANONICAL_JOINTS
from groove_eval.generate_golden_clips import generate_golden_dataset
from groove_eval.lesson_package import load_schema, slice_reference, validate_manifest
from groove_eval.scoring import (
    MIRROR_SWAP_PAIRS,
    REQUIRED_BODY_JOINTS,
    REQUIRED_FOOT_JOINTS,
    load_config,
    score_attempt,
    score_coverage,
    score_foot_coverage,
)

ROOT = Path(__file__).resolve().parent.parent
LESSON_PATH = ROOT / "authoring" / "lessons" / "img4941.lesson.json"
FETCH_POSE_SCRIPT = ROOT / "ios" / "GrooveApp" / "Resources" / "fetch_pose_model.sh"


class TestBeatGrid(unittest.TestCase):
    """Beat grid proposal and generation tests."""

    def test_beat_this_license_is_mit(self) -> None:
        self.assertEqual(BEAT_THIS_LICENSE, "MIT")

    def test_build_beat_grid_properties(self) -> None:
        grid = build_beat_grid(bpm=120.0, anchor_s=0.5, duration_s=4.5)
        self.assertEqual(grid["bpm"], 120.0)
        self.assertEqual(grid["anchor_s"], 0.5)
        self.assertEqual(grid["source"], "author_confirmed")

        beats = grid["beats"]
        self.assertGreater(len(beats), 0)
        self.assertEqual(beats[0]["t"], 0.5)
        self.assertEqual(beats[0]["phrase"], 1)
        self.assertEqual(beats[0]["count"], 1)

        # Monotonically increasing and strictly 0.5s interval
        for i in range(1, len(beats)):
            self.assertGreater(beats[i]["t"], beats[i - 1]["t"])
            self.assertAlmostEqual(beats[i]["t"] - beats[i - 1]["t"], 0.5, places=3)
            # Count sequence 1..8
            expected_count = ((i) % 8) + 1
            expected_phrase = (i // 8) + 1
            self.assertEqual(beats[i]["count"], expected_count)
            self.assertEqual(beats[i]["phrase"], expected_phrase)

    def test_img4941_confirmed_beat_grid_alignment(self) -> None:
        # 112.5 BPM, anchor 0.53 s, duration 16.33 s
        grid = build_beat_grid(bpm=112.5, anchor_s=0.53, duration_s=16.33)
        beats = grid["beats"]
        self.assertEqual(beats[0]["t"], 0.53)
        self.assertEqual(beats[0]["count"], 1)
        self.assertEqual(beats[1]["t"], 1.063)
        self.assertEqual(beats[8]["t"], 4.797)  # Near 4.80 s Segment A cut
        self.assertLess(abs(beats[8]["t"] - 4.80), 0.040)
        self.assertLess(beats[-1]["t"], 16.33)


class TestLessonSourceAndManifest(unittest.TestCase):
    """Validation of img4941.lesson.json and manifest assembly."""

    def test_lesson_source_exists_and_parses(self) -> None:
        self.assertTrue(LESSON_PATH.exists(), f"Missing {LESSON_PATH}")
        with open(LESSON_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)

        self.assertEqual(data["course_slug"], "bollywood-basics")
        self.assertEqual(data["lesson_slug"], "img4941-routine")
        self.assertEqual(data["package_version"], 1)
        self.assertFalse(data["video"]["mirrored"])
        self.assertTrue(data["video"]["default_display_flip"])

        # Segments A, B, C, D, full
        seg_ids = [s["id"] for s in data["segments"]]
        self.assertEqual(seg_ids, ["A", "B", "C", "D", "full"])
        teach_orders = [s["teach_order"] for s in data["segments"]]
        self.assertEqual(teach_orders, [1, 2, 3, 4, 5])

        # Clasp windows
        windows = data["windows"]
        self.assertEqual(len(windows), 2)
        self.assertEqual(windows[0]["kind"], "clasp")
        self.assertEqual(windows[0]["start_s"], 4.80)
        self.assertEqual(windows[0]["end_s"], 5.87)
        self.assertEqual(windows[1]["kind"], "clasp")
        self.assertEqual(windows[1]["start_s"], 12.75)
        self.assertEqual(windows[1]["end_s"], 13.65)

    def test_assemble_and_validate_manifest(self) -> None:
        with open(LESSON_PATH, "r", encoding="utf-8") as f:
            source = json.load(f)

        video_meta = {
            "duration_s": 16.33,
            "fps": 30.0,
            "width": 720,
            "height": 1280,
        }
        beat_grid = build_beat_grid(112.5, 0.53, 16.33)
        files_sha = {
            "video.mp4": "a" * 64,
            "reference_pose.json": "b" * 64,
            "poster.jpg": "c" * 64,
        }

        manifest = assemble_manifest(
            lesson_source=source,
            video_meta=video_meta,
            reference_frame_count=490,
            beat_grid=beat_grid,
            files_sha256=files_sha,
        )

        errors = validate_manifest(manifest)
        self.assertEqual(errors, [], f"Manifest validation errors: {errors}")


class TestExtractPoseAndSmoothing(unittest.TestCase):
    """Tests for pose extraction helper logic and One Euro smoothing."""

    def test_pose_model_sha256_matches_shell_script(self) -> None:
        self.assertTrue(FETCH_POSE_SCRIPT.exists(), f"Missing {FETCH_POSE_SCRIPT}")
        with open(FETCH_POSE_SCRIPT, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn(POSE_MODEL_SHA256, content)

    def test_hand_model_sha256_is_pinned(self) -> None:
        self.assertEqual(len(HAND_MODEL_SHA256), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in HAND_MODEL_SHA256))

    def test_round_frame_coordinates(self) -> None:
        frame = {
            "t": 0.1234567,
            "joints": {"nose": [0.111199, -0.222211, 0.333399]},
            "confidences": {"nose": 0.987654},
            "hands": {"left": [[0.555511, 0.666622, -0.777788]]},
        }
        rounded = round_frame_coordinates(frame, 4)
        self.assertEqual(rounded["t"], 0.1235)
        self.assertEqual(rounded["joints"]["nose"], [0.1112, -0.2222, 0.3334])
        self.assertEqual(rounded["confidences"]["nose"], 0.9877)
        self.assertEqual(rounded["hands"]["left"], [[0.5555, 0.6666, -0.7778]])

    def test_one_euro_smoothing_reduces_noise(self) -> None:
        # Create noisy synthetic frames
        dt = 0.0333
        frames = []
        for i in range(30):
            t = i * dt
            # True signal is 0.5, noise is +/-0.05 alternating
            noise = 0.05 if (i % 2 == 0) else -0.05
            frames.append({
                "t": t,
                "joints": {"rightWrist": [0.2, 0.5 + noise, -0.1]},
            })

        smoothed = smooth_canonical_frames(frames)
        self.assertEqual(len(smoothed), len(frames))

        # Check that variance of differences frame-to-frame is reduced
        raw_diffs = [abs(frames[i]["joints"]["rightWrist"][1] - frames[i - 1]["joints"]["rightWrist"][1]) for i in range(1, len(frames))]
        smooth_diffs = [abs(smoothed[i]["joints"]["rightWrist"][1] - smoothed[i - 1]["joints"]["rightWrist"][1]) for i in range(1, len(smoothed))]

        self.assertLess(sum(smooth_diffs), sum(raw_diffs))


class TestV1ValidationRules(unittest.TestCase):
    """Spec §5 V1 checks: coverage, self-comparison, +150ms shift fails, left/right swap fails."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.config = load_config()
        golden = generate_golden_dataset()
        raw_ref = golden["references"]["down_bounce"]

        # Build asymmetric reference clip (simulating Segment A with asymmetric left foot tap)
        ref = copy.deepcopy(raw_ref)
        ref["clip_id"] = "test_asymmetric_ref"
        ref["move_tag"] = "A"
        for f in ref["frames"]:
            f["joints"]["leftFootIndex"][1] += 0.12  # Asymmetric foot pitch
        cls.ref_clip = ref

    def test_coverage_metric_on_reference_clip(self) -> None:
        cov = score_coverage(self.ref_clip["frames"], min_confidence=0.50)
        foot_cov = score_foot_coverage(self.ref_clip["frames"], min_confidence=0.50)
        self.assertGreaterEqual(cov, 0.95)
        self.assertGreaterEqual(foot_cov, 0.90)

    def test_reference_vs_itself_passes_with_high_shape(self) -> None:
        result = score_attempt(self.ref_clip, self.ref_clip, self.config)
        self.assertTrue(result["passed"])
        self.assertGreaterEqual(result["shape"]["shape_score"], 95.0)

    def test_shifted_attempt_fails_timing(self) -> None:
        # Shift timestamps by +150 ms
        shifted_frames = []
        for f in self.ref_clip["frames"]:
            sf = copy.deepcopy(f)
            sf["t"] = f["t"] + 0.150
            shifted_frames.append(sf)
        shifted_clip = copy.deepcopy(self.ref_clip)
        shifted_clip["frames"] = shifted_frames

        result = score_attempt(shifted_clip, self.ref_clip, self.config)
        self.assertFalse(result["passed"])
        self.assertLess(result["timing"]["good_or_better_ratio"], 0.80)

    def test_left_right_swap_fails_shape_on_asymmetric_segment(self) -> None:
        # Swap left and right joints
        swapped_frames = []
        for f in self.ref_clip["frames"]:
            j = copy.deepcopy(f["joints"])
            for l_j, r_j in MIRROR_SWAP_PAIRS:
                if l_j in j and r_j in j:
                    j[l_j], j[r_j] = j[r_j], j[l_j]
            # Invert X axis
            j = {k: [-v[0], v[1], v[2]] for k, v in j.items()}
            sf = copy.deepcopy(f)
            sf["joints"] = j
            swapped_frames.append(sf)

        swapped_clip = copy.deepcopy(self.ref_clip)
        swapped_clip["frames"] = swapped_frames

        result = score_attempt(swapped_clip, self.ref_clip, self.config)
        # Asymmetrical posture swapped side should fail shape
        self.assertFalse(result["passed"])
        self.assertLess(result["shape"]["shape_score"], 70.0)


if __name__ == "__main__":
    unittest.main()
