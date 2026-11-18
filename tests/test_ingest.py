"""CI-safe unit tests for authoring/ingest.py and authoring/recut.py (WO yt-ingest).

Tests cover:
- Scene cut detection stderr parsing
- Contiguous shot calculation
- Fixed timemap generation & bidirectional math (out_to_src, src_to_out)
- Crop and horizontal flip filter string generation
- Filter complex construction with and without audio
- Cut plan validation (out-of-range, negative timestamps, overlaps, crop bounds)
- Mocked subprocess ingest execution (CI-safe, no ffmpeg/network required)
- Mocked subprocess recut execution (CI-safe, no ffmpeg required)
- Requirements pinning verification
"""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from authoring.ingest import (
    IngestResult,
    detect_shot_cuts,
    get_default_output_dir,
    ingest,
    is_url,
    parse_scene_cuts,
    probe_metadata,
    shots_from_cuts,
)
from authoring.recut import (
    build_crop_flip_filter,
    build_filter_complex,
    build_timemap,
    out_to_src,
    parse_crop_box,
    parse_cut_plan,
    recut,
    src_to_out,
    validate_cut_plan,
)


class TestIngestParsingAndMath(unittest.TestCase):
    def test_parse_scene_cuts(self):
        sample_stderr = """
[Parsed_showinfo_1 @ 0x123] n: 10 pts: 200 pts_time:1.500000 fmt:yuv420p
[Parsed_showinfo_1 @ 0x123] n: 11 pts: 201 pts_time:1.520000 fmt:yuv420p  # within 0.05s duplicate
[Parsed_showinfo_1 @ 0x123] n: 45 pts: 600 pts_time:4.250000 fmt:yuv420p
[Parsed_showinfo_1 @ 0x123] n: 90 pts: 1200 pts_time:8.100000 fmt:yuv420p
[Parsed_showinfo_1 @ 0x123] n: 150 pts: 2000 pts_time:16.500000 fmt:yuv420p
        """
        cuts = parse_scene_cuts(sample_stderr, duration_s=15.0)
        # 16.5 exceeds 15.0 duration, 1.52 is deduplicated
        self.assertEqual(cuts, [1.5, 4.25, 8.1])

    def test_shots_from_cuts_no_cuts(self):
        shots = shots_from_cuts([], duration_s=16.333)
        self.assertEqual(len(shots), 1)
        self.assertEqual(shots[0]["start_s"], 0.0)
        self.assertEqual(shots[0]["end_s"], 16.333)
        self.assertEqual(shots[0]["duration_s"], 16.333)

    def test_shots_from_cuts_with_cuts(self):
        cuts = [3.5, 8.0]
        shots = shots_from_cuts(cuts, duration_s=10.0)
        self.assertEqual(len(shots), 3)
        self.assertEqual(shots[0], {"start_s": 0.0, "end_s": 3.5, "duration_s": 3.5})
        self.assertEqual(shots[1], {"start_s": 3.5, "end_s": 8.0, "duration_s": 4.5})
        self.assertEqual(shots[2], {"start_s": 8.0, "end_s": 10.0, "duration_s": 2.0})

    def test_is_url(self):
        self.assertTrue(is_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        self.assertTrue(is_url("http://youtu.be/dQw4w9WgXcQ"))
        self.assertFalse(is_url("C:\\Users\\fahim\\Downloads\\IMG_4941.mov"))
        self.assertFalse(is_url("/home/user/video.mp4"))


class TestRecutTimemapAndFilters(unittest.TestCase):
    def test_timemap_single_cut(self):
        cuts = [{"src_start_s": 0.53, "src_end_s": 14.80}]
        timemap = build_timemap(cuts)
        self.assertEqual(len(timemap), 1)
        self.assertEqual(timemap[0]["out_start_s"], 0.0)
        self.assertEqual(timemap[0]["src_start_s"], 0.53)
        self.assertEqual(timemap[0]["dur_s"], 14.27)

    def test_timemap_fixed_shape_multi_cut(self):
        cuts = [
            {"src_start_s": 0.53, "src_end_s": 4.80},
            {"src_start_s": 6.40, "src_end_s": 9.07},
            {"src_start_s": 10.00, "src_end_s": 12.50},
        ]
        timemap = build_timemap(cuts)
        self.assertEqual(len(timemap), 3)

        # Validate fixed shape
        for entry in timemap:
            self.assertEqual(set(entry.keys()), {"out_start_s", "src_start_s", "dur_s"})
            self.assertIsInstance(entry["out_start_s"], float)
            self.assertIsInstance(entry["src_start_s"], float)
            self.assertIsInstance(entry["dur_s"], float)

        self.assertAlmostEqual(timemap[0]["out_start_s"], 0.0)
        self.assertAlmostEqual(timemap[0]["src_start_s"], 0.53)
        self.assertAlmostEqual(timemap[0]["dur_s"], 4.27)

        self.assertAlmostEqual(timemap[1]["out_start_s"], 4.27)
        self.assertAlmostEqual(timemap[1]["src_start_s"], 6.40)
        self.assertAlmostEqual(timemap[1]["dur_s"], 2.67)

        self.assertAlmostEqual(timemap[2]["out_start_s"], 6.94)
        self.assertAlmostEqual(timemap[2]["src_start_s"], 10.00)
        self.assertAlmostEqual(timemap[2]["dur_s"], 2.50)

    def test_timemap_bidirectional_lookup(self):
        cuts = [
            {"src_start_s": 1.0, "src_end_s": 4.0},   # dur 3.0, out: 0.0 - 3.0
            {"src_start_s": 10.0, "src_end_s": 15.0}, # dur 5.0, out: 3.0 - 8.0
        ]
        timemap = build_timemap(cuts)

        # out_to_src
        self.assertAlmostEqual(out_to_src(0.0, timemap), 1.0)
        self.assertAlmostEqual(out_to_src(1.5, timemap), 2.5)
        self.assertAlmostEqual(out_to_src(3.0, timemap), 4.0)
        self.assertAlmostEqual(out_to_src(4.0, timemap), 11.0)
        self.assertAlmostEqual(out_to_src(8.0, timemap), 15.0)

        # src_to_out
        self.assertAlmostEqual(src_to_out(1.0, timemap), 0.0)
        self.assertAlmostEqual(src_to_out(2.5, timemap), 1.5)
        self.assertAlmostEqual(src_to_out(4.0, timemap), 3.0)
        # Point inside cut out gap (e.g. 7.0s) should return None
        self.assertIsNone(src_to_out(7.0, timemap))
        self.assertAlmostEqual(src_to_out(12.0, timemap), 5.0)

    def test_crop_flip_filter_strings(self):
        # Empty
        self.assertEqual(build_crop_flip_filter(None, False), "")

        # Flip only
        self.assertEqual(build_crop_flip_filter(None, True), "hflip")

        # Crop dict
        crop = parse_crop_box({"x": 100, "y": 50, "w": 400, "h": 600})
        self.assertEqual(build_crop_flip_filter(crop, False), "crop=400:600:100:50")

        # Crop odd dimension normalization to even
        crop_odd = parse_crop_box({"x": 10, "y": 20, "w": 401, "h": 599})
        self.assertEqual(crop_odd["w"], 400)
        self.assertEqual(crop_odd["h"], 598)
        self.assertEqual(build_crop_flip_filter(crop_odd, False), "crop=400:598:10:20")

        # Crop and flip
        self.assertEqual(build_crop_flip_filter(crop, True), "crop=400:600:100:50,hflip")

    def test_build_filter_complex(self):
        cuts = [
            {"src_start_s": 0.53, "src_end_s": 4.80, "crop": {"x": 80, "y": 0, "w": 560, "h": 1280}, "hflip": True},
            {"src_start_s": 6.40, "src_end_s": 9.07, "crop": {"x": 80, "y": 0, "w": 560, "h": 1280}, "hflip": True},
        ]
        # With audio
        fc = build_filter_complex(cuts, has_audio=True)
        self.assertIn("trim=start=0.53:end=4.8", fc)
        self.assertIn("crop=560:1280:80:0,hflip", fc)
        self.assertIn("atrim=start=0.53:end=4.8", fc)
        self.assertIn("concat=n=2:v=1:a=1[outv][outa]", fc)

        # Without audio
        fc_no_audio = build_filter_complex(cuts, has_audio=False)
        self.assertNotIn("atrim", fc_no_audio)
        self.assertIn("concat=n=2:v=1:a=0[outv]", fc_no_audio)


class TestPlanValidation(unittest.TestCase):
    def test_valid_plan(self):
        cuts = [
            {"src_start_s": 0.53, "src_end_s": 4.80, "crop": {"x": 0, "y": 0, "w": 500, "h": 1000}},
            {"src_start_s": 5.00, "src_end_s": 10.00, "crop": {"x": 0, "y": 0, "w": 500, "h": 1000}},
        ]
        validate_cut_plan(cuts, duration_s=15.0, width=720, height=1280)

    def test_empty_cuts_raises(self):
        with self.assertRaises(ValueError):
            validate_cut_plan([])

    def test_negative_start_raises(self):
        cuts = [{"src_start_s": -1.0, "src_end_s": 5.0}]
        with self.assertRaises(ValueError):
            validate_cut_plan(cuts)

    def test_end_before_start_raises(self):
        cuts = [{"src_start_s": 5.0, "src_end_s": 4.0}]
        with self.assertRaises(ValueError):
            validate_cut_plan(cuts)

    def test_out_of_range_duration_raises(self):
        cuts = [{"src_start_s": 5.0, "src_end_s": 25.0}]
        with self.assertRaises(ValueError):
            validate_cut_plan(cuts, duration_s=20.0)

    def test_overlapping_cuts_raises(self):
        cuts = [
            {"src_start_s": 1.0, "src_end_s": 5.0},
            {"src_start_s": 4.0, "src_end_s": 8.0},
        ]
        with self.assertRaises(ValueError) as ctx:
            validate_cut_plan(cuts)
        self.assertIn("Overlapping cuts detected", str(ctx.exception))

    def test_crop_out_of_bounds_raises(self):
        cuts = [{"src_start_s": 1.0, "src_end_s": 5.0, "crop": {"x": 500, "y": 0, "w": 300, "h": 1280}}]
        with self.assertRaises(ValueError):
            validate_cut_plan(cuts, width=720, height=1280)


class TestMockSubprocessPipelines(unittest.TestCase):
    @patch("shutil.which")
    @patch("subprocess.run")
    def test_ingest_mock_pipeline(self, mock_run, mock_which):
        mock_which.return_value = "ffmpeg"

        # Mock ffprobe metadata output
        mock_ffprobe_json = json.dumps({
            "streams": [
                {
                    "codec_type": "video",
                    "width": 720,
                    "height": 1280,
                    "r_frame_rate": "30/1",
                    "duration": "16.333",
                },
                {
                    "codec_type": "audio",
                    "codec_name": "aac",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
            "format": {"duration": "16.333"}
        })

        # Mock shot cut detection output
        mock_scene_stderr = "[Parsed_showinfo_1 @ 0x1] n: 10 pts_time:4.500000"

        def fake_run(cmd, *args, **kwargs):
            res = MagicMock()
            res.returncode = 0
            if "ffprobe" in cmd[0] or "-show_entries" in cmd:
                res.stdout = mock_ffprobe_json
                res.stderr = ""
            elif "select='gt(scene" in str(cmd):
                res.stdout = ""
                res.stderr = mock_scene_stderr
            else:
                res.stdout = ""
                res.stderr = ""
            return res

        mock_run.side_effect = fake_run

        with tempfile.TemporaryDirectory() as td:
            dummy_video = Path(td) / "dummy.mov"
            dummy_video.write_bytes(b"mock video data")
            out_dir = Path(td) / "out"

            result = ingest(dummy_video, out_dir=out_dir)

            self.assertTrue(result.json_path.exists())
            with open(result.json_path, "r", encoding="utf-8") as f:
                saved = json.load(f)

            self.assertEqual(saved["metadata"]["width"], 720)
            self.assertEqual(saved["metadata"]["height"], 1280)
            self.assertEqual(saved["cuts"], [4.5])
            self.assertEqual(len(saved["shots"]), 2)
            self.assertEqual(saved["shots"][0]["end_s"], 4.5)
            self.assertEqual(saved["shots"][1]["start_s"], 4.5)

    @patch("shutil.which")
    @patch("subprocess.run")
    def test_recut_mock_pipeline(self, mock_run, mock_which):
        mock_which.return_value = "ffmpeg"
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as td:
            video_file = Path(td) / "source.mp4"
            video_file.write_bytes(b"dummy")

            ingest_json = Path(td) / "ingest.json"
            ingest_data = {
                "video_path": str(video_file),
                "metadata": {"duration_s": 20.0, "width": 720, "height": 1280, "has_audio": True}
            }
            ingest_json.write_text(json.dumps(ingest_data), encoding="utf-8")

            cut_plan = {
                "cuts": [
                    {"src_start_s": 0.53, "src_end_s": 14.80}
                ],
                "crop": {"x": 80, "y": 0, "w": 560, "h": 1280},
                "hflip": True
            }
            cut_plan_json = Path(td) / "cut_plan.json"
            cut_plan_json.write_text(json.dumps(cut_plan), encoding="utf-8")

            out_video = Path(td) / "output_recut.mp4"
            res_path = recut(ingest_json, cut_plan_json, out_path=out_video)

            self.assertEqual(res_path, out_video)
            timemap_path = out_video.with_name("output_recut.timemap.json")
            self.assertTrue(timemap_path.exists())

            with open(timemap_path, "r", encoding="utf-8") as f:
                timemap = json.load(f)

            self.assertEqual(len(timemap), 1)
            self.assertEqual(timemap[0]["out_start_s"], 0.0)
            self.assertEqual(timemap[0]["src_start_s"], 0.53)
            self.assertEqual(timemap[0]["dur_s"], 14.27)


class TestRequirementsPinned(unittest.TestCase):
    def test_requirements_contains_pinned_ytdlp(self):
        req_path = Path(__file__).resolve().parent.parent / "authoring" / "requirements.txt"
        self.assertTrue(req_path.exists())
        content = req_path.read_text(encoding="utf-8")
        self.assertIn("yt-dlp==2026.7.4", content)


if __name__ == "__main__":
    unittest.main()
