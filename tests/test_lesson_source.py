"""Unit tests for Argon breakdown validation and lesson source conversion (WO: argon-lesson-source)."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path
from typing import Any, Dict

from authoring.beat_grid import build_beat_grid
from authoring.build_package import assemble_manifest
from authoring.lesson_source import (
    build_timemap_from_cut_plan,
    load_breakdown_schema,
    map_src_to_out,
    slugify,
    to_lesson_source,
    validate_breakdown,
    validate_timemap,
)
from groove_eval.lesson_package import validate_manifest

ROOT = Path(__file__).resolve().parent.parent
FIXTURE_PATH = ROOT / "fixtures" / "argon" / "img4941_breakdown.json"


class TestArgonLessonSource(unittest.TestCase):
    """Test suite for argon breakdown schema, validation, conversion, and manifest assembly."""

    def setUp(self) -> None:
        self.assertTrue(FIXTURE_PATH.exists(), f"Missing fixture {FIXTURE_PATH}")
        with open(FIXTURE_PATH, "r", encoding="utf-8") as f:
            self.breakdown: Dict[str, Any] = json.load(f)

    def test_schema_loads_properly(self) -> None:
        schema = load_breakdown_schema()
        self.assertEqual(schema["title"], "Argon dance video breakdown response")
        self.assertIn("source", schema["required"])
        self.assertIn("cut_plan", schema["required"])

    def test_img4941_breakdown_validates(self) -> None:
        errors = validate_breakdown(self.breakdown)
        self.assertEqual(errors, [], f"Expected clean validation, got: {errors}")

    def test_img4941_converts_and_assembles_manifest_recut(self) -> None:
        # 1. Recut timemap shifting 0.53 s -> 0.0 s
        recut_timemap = [
            {
                "out_start_s": 0.0,
                "src_start_s": 0.53,
                "dur_s": 14.40,
            }
        ]
        source = to_lesson_source(self.breakdown, timemap=recut_timemap)

        # Provenance checks
        self.assertIn("provenance", source)
        self.assertEqual(source["provenance"]["source_url"], self.breakdown["source"]["url"])
        self.assertEqual(source["provenance"]["title"], self.breakdown["source"]["title"])
        self.assertEqual(source["provenance"]["pipeline"], "argon")

        # Times mapped to recut timeline
        self.assertEqual(source["beat_grid"]["bpm"], 112.5)
        self.assertEqual(source["beat_grid"]["anchor_s"], 0.0)

        seg_a = next(s for s in source["segments"] if s["id"] == "A")
        self.assertEqual(seg_a["start_s"], 0.0)
        self.assertEqual(seg_a["end_s"], 4.27)

        # 2. Assemble manifest and validate against groove.lesson/1 contract
        dur = 14.40
        beat_grid = build_beat_grid(
            bpm=source["beat_grid"]["bpm"],
            anchor_s=source["beat_grid"]["anchor_s"],
            duration_s=dur,
        )
        video_meta = {
            "duration_s": dur,
            "fps": 30.0,
            "width": 720,
            "height": 1280,
        }
        files_sha = {
            "video.mp4": "a" * 64,
            "reference_pose.json": "b" * 64,
            "poster.jpg": "c" * 64,
        }
        manifest = assemble_manifest(
            lesson_source=source,
            video_meta=video_meta,
            reference_frame_count=432,
            beat_grid=beat_grid,
            files_sha256=files_sha,
        )
        errors = validate_manifest(manifest)
        self.assertEqual(errors, [], f"Manifest validation errors: {errors}")

    def test_img4941_converts_and_assembles_manifest_identity_timemap(self) -> None:
        identity_timemap = [
            {
                "out_start_s": 0.0,
                "src_start_s": 0.0,
                "dur_s": 16.33,
            }
        ]
        source = to_lesson_source(self.breakdown, timemap=identity_timemap)
        self.assertEqual(source["beat_grid"]["anchor_s"], 0.53)

        dur = 16.33
        beat_grid = build_beat_grid(
            bpm=source["beat_grid"]["bpm"],
            anchor_s=source["beat_grid"]["anchor_s"],
            duration_s=dur,
        )
        video_meta = {
            "duration_s": dur,
            "fps": 30.0,
            "width": 720,
            "height": 1280,
        }
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

    def test_negative_segment_across_cut(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        # Introduce a cut at 4.0 s inside Segment A (0.53 - 4.80)
        doc["shots"] = [
            {"start_s": 0.0, "end_s": 0.53, "camera": "moving", "usable": False, "why": "pre-roll"},
            {"start_s": 0.53, "end_s": 4.0, "camera": "static", "usable": True, "why": "shot 1"},
            {"start_s": 4.0, "end_s": 14.93, "camera": "static", "usable": True, "why": "shot 2"},
            {"start_s": 14.93, "end_s": 16.33, "camera": "moving", "usable": False, "why": "post-roll"},
        ]
        errors = validate_breakdown(doc)
        self.assertTrue(any("not wholly contained within a single usable shot" in e for e in errors))

    def test_negative_segment_in_unusable_shot(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        # Mark the main shot unusable
        doc["shots"][1]["usable"] = False
        errors = validate_breakdown(doc)
        self.assertTrue(any("not wholly contained within a single usable shot" in e for e in errors))

    def test_negative_off_beat_boundary(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        # Change Segment A end_s to 3.0 s (at 112.5 BPM, beats are 2.67 and 3.20; 3.0 is off by ~133 ms)
        doc["segments"][0]["end_s"] = 3.0
        doc["segments"][1]["start_s"] = 3.0
        errors = validate_breakdown(doc)
        self.assertTrue(any("not within 40 ms of bpm grid" in e for e in errors))

    def test_negative_segment_outside_cut_plan(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        # Cut plan truncates before Segment D finishes
        doc["cut_plan"] = [{"src_start_s": 0.53, "src_end_s": 9.07}]
        errors = validate_breakdown(doc)
        self.assertTrue(any("is not wholly contained within a cut_plan interval" in e for e in errors))

    def test_negative_cut_plan_outside_duration(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        # Cut plan ends at 20.0 s, video duration is 16.33 s
        doc["cut_plan"] = [{"src_start_s": 0.53, "src_end_s": 20.0}]
        errors = validate_breakdown(doc)
        self.assertTrue(any("need 0 <= src_start_s < src_end_s <= source.duration_s" in e for e in errors))

    def test_negative_missing_target_dancer(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        doc["target_dancer_id"] = "unknown_dancer"
        errors = validate_breakdown(doc)
        self.assertTrue(any("target_dancer_id" in e for e in errors))

    def test_negative_duplicate_segment_id(self) -> None:
        doc = copy.deepcopy(self.breakdown)
        doc["segments"][1]["id"] = "A"
        errors = validate_breakdown(doc)
        self.assertTrue(any("duplicate segment id 'A'" in e for e in errors))

    def test_timemap_validation_and_mapping(self) -> None:
        tm = [
            {"out_start_s": 0.0, "src_start_s": 1.0, "dur_s": 5.0},
            {"out_start_s": 5.0, "src_start_s": 10.0, "dur_s": 4.0},
        ]
        self.assertEqual(validate_timemap(tm), [])

        # Valid mappings
        self.assertAlmostEqual(map_src_to_out(1.0, tm), 0.0)
        self.assertAlmostEqual(map_src_to_out(3.5, tm), 2.5)
        self.assertAlmostEqual(map_src_to_out(12.0, tm), 7.0)

        # Mapping out of range
        with self.assertRaises(ValueError):
            map_src_to_out(8.0, tm)

        # Non-contiguous timemap error
        bad_tm = [
            {"out_start_s": 0.0, "src_start_s": 1.0, "dur_s": 5.0},
            {"out_start_s": 6.0, "src_start_s": 10.0, "dur_s": 4.0},
        ]
        tm_errs = validate_timemap(bad_tm)
        self.assertTrue(any("expected contiguous start" in e for e in tm_errs))

    def test_slugify(self) -> None:
        self.assertEqual(slugify("Bollywood / Desi Pop Filmi Choreography"), "bollywood-desi-pop-filmi-choreography")
        self.assertEqual(slugify("Filmi Routine 1!"), "filmi-routine-1")
        self.assertEqual(slugify("---special @# chars---"), "special-chars")
        self.assertEqual(slugify(""), "routine")


if __name__ == "__main__":
    unittest.main()
