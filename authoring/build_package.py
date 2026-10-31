"""Lesson package builder for Groove Coach (spec §2.2, WO-1C).

Takes a hand-written lesson source (*.lesson.json) + video -> validated package directory:
- manifest.json (validated by groove_eval.lesson_package)
- video.mp4 (H.264/AAC, faststart, via ffmpeg)
- reference_pose.json (canonical PoseClip)
- poster.jpg
- files SHA256 map
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from authoring.beat_grid import build_beat_grid
from authoring.extract_pose import (
    MEDIAPIPE_PYTHON_VERSION,
    POSE_MODEL_NAME,
    POSE_MODEL_SHA256,
    extract_pose_clip,
    sha256_of_file,
)
from groove_eval.lesson_package import validate_manifest


def get_video_metadata(video_path: Path) -> Dict[str, Any]:
    """Retrieve video duration, fps, width, height using ffprobe or OpenCV."""
    ffprobe_bin = shutil.which("ffprobe")
    if ffprobe_bin:
        cmd = [
            ffprobe_bin,
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate,duration",
            "-show_entries", "format=duration",
            "-of", "json",
            str(video_path),
        ]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        data = json.loads(res.stdout)
        stream = data["streams"][0]
        width = int(stream["width"])
        height = int(stream["height"])

        # Frame rate e.g. "30/1" or "30000/1001"
        r_fps = stream.get("r_frame_rate", "30/1")
        if "/" in r_fps:
            num, den = r_fps.split("/")
            fps = float(num) / max(1.0, float(den))
        else:
            fps = float(r_fps)

        dur_str = stream.get("duration") or data.get("format", {}).get("duration") or "0"
        duration_s = float(dur_str)
        return {
            "width": width,
            "height": height,
            "fps": round(fps, 2),
            "duration_s": round(duration_s, 2),
        }

    # Fallback to cv2
    try:
        import cv2
        cap = cv2.VideoCapture(str(video_path))
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = float(cap.get(cv2.CAP_PROP_FPS) or 30.0)
        frames = cap.get(cv2.CAP_PROP_FRAME_COUNT)
        duration_s = frames / fps if fps > 0 else 0.0
        cap.release()
        return {
            "width": width,
            "height": height,
            "fps": round(fps, 2),
            "duration_s": round(duration_s, 2),
        }
    except Exception as e:
        raise RuntimeError(f"Cannot probe video {video_path}: {e}")


def transcode_video_for_package(source_path: Path, target_path: Path) -> None:
    """Encode video to web/iOS-standard H.264/AAC with faststart (spec §2.2)."""
    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError("ffmpeg not found on PATH; required for video transcoding.")

    target_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg_bin,
        "-y",
        "-i", str(source_path),
        "-c:v", "libx264",
        "-profile:v", "high",
        "-level", "4.1",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", "192k",
        "-movflags", "+faststart",
        str(target_path),
    ]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)


def extract_poster_image(video_path: Path, poster_path: Path, timestamp_s: float = 0.53) -> None:
    """Extract a single representative poster JPEG from the video."""
    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError("ffmpeg not found on PATH; required for poster extraction.")

    poster_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg_bin,
        "-y",
        "-ss", str(max(0.0, timestamp_s)),
        "-i", str(video_path),
        "-vframes", "1",
        "-q:v", "2",
        str(poster_path),
    ]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)


def assemble_manifest(
    lesson_source: Mapping[str, Any],
    video_meta: Mapping[str, Any],
    reference_frame_count: int,
    beat_grid: Mapping[str, Any],
    files_sha256: Mapping[str, str],
) -> Dict[str, Any]:
    """Assemble the complete dictionary for manifest.json and validate against schema & rules."""
    video_source = lesson_source.get("video", {})
    manifest: Dict[str, Any] = {
        "schema": "groove.lesson/1",
        "lesson_id": lesson_source["lesson_id"],
        "course_slug": lesson_source["course_slug"],
        "lesson_slug": lesson_source["lesson_slug"],
        "package_version": int(lesson_source.get("package_version", 1)),
        "title": lesson_source["title"],
        "requires": lesson_source.get("requires", {
            "engine_major": 2,
            "skeleton": "groove.canonical/1",
        }),
        "extractor": {
            "pose_model": POSE_MODEL_NAME,
            "pose_model_sha256": POSE_MODEL_SHA256,
            "mediapipe_python": MEDIAPIPE_PYTHON_VERSION,
            "running_mode": "VIDEO",
            "num_poses": 1,
        },
        "video": {
            "file": "video.mp4",
            "duration_s": float(video_meta["duration_s"]),
            "fps": float(video_meta["fps"]),
            "width": int(video_meta["width"]),
            "height": int(video_meta["height"]),
            "mirrored": bool(video_source.get("mirrored", False)),
            "default_display_flip": bool(video_source.get("default_display_flip", True)),
        },
        "poster": "poster.jpg",
        "reference": {
            "file": "reference_pose.json",
            "frame_count": int(reference_frame_count),
        },
        "beat_grid": beat_grid,
        "segments": list(lesson_source["segments"]),
        "windows": list(lesson_source.get("windows", [])),
        "config_overrides": dict(lesson_source.get("config_overrides", {})),
        "practice": dict(lesson_source.get("practice", {})),
        "files": dict(files_sha256),
    }

    # Validate against groove_eval.lesson_package contract
    errors = validate_manifest(manifest)
    if errors:
        raise ValueError("Manifest validation failed: " + "; ".join(errors))

    return manifest


def build_package(
    lesson_source_path: Path,
    video_path: Path,
    output_dir: Path,
    *,
    transcode: bool = True,
    extract_pose: bool = True,
    include_hands: bool = True,
) -> Dict[str, Any]:
    """Execute complete lesson package build into output_dir."""
    lesson_source_path = Path(lesson_source_path)
    video_path = Path(video_path)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with open(lesson_source_path, "r", encoding="utf-8") as f:
        lesson_source = json.load(f)

    # 1. Video processing
    package_video_path = output_dir / "video.mp4"
    if transcode:
        print(f"Transcoding {video_path} -> {package_video_path}...", file=sys.stderr)
        transcode_video_for_package(video_path, package_video_path)
        meta_source = package_video_path
    else:
        meta_source = video_path
        if not package_video_path.exists():
            shutil.copy2(video_path, package_video_path)

    video_meta = get_video_metadata(meta_source)
    print(f"Video metadata: {video_meta['width']}x{video_meta['height']} @ {video_meta['fps']} fps, {video_meta['duration_s']} s", file=sys.stderr)

    # 2. Poster image
    poster_path = output_dir / "poster.jpg"
    anchor = float(lesson_source.get("beat_grid", {}).get("anchor_s", 0.53))
    print(f"Extracting poster at {anchor} s -> {poster_path}...", file=sys.stderr)
    extract_poster_image(meta_source, poster_path, timestamp_s=anchor)

    # 3. Beat grid
    bg_conf = lesson_source.get("beat_grid", {})
    bpm = float(bg_conf.get("bpm", 112.5))
    beat_grid = build_beat_grid(
        bpm=bpm,
        anchor_s=anchor,
        duration_s=float(video_meta["duration_s"]),
        source=bg_conf.get("source", "author_confirmed"),
        detector=bg_conf.get("detector", "beat_this_small_cpu"),
    )
    beat_times = [b["t"] for b in beat_grid["beats"]]

    # 4. Extract pose
    ref_pose_path = output_dir / "reference_pose.json"
    if extract_pose:
        print(f"Extracting reference pose from {meta_source} -> {ref_pose_path}...", file=sys.stderr)
        pose_clip = extract_pose_clip(
            meta_source,
            include_hands=include_hands,
            smooth=True,
            bpm=bpm,
            beat_times=beat_times,
            clip_id=f"{lesson_source['lesson_slug']}/reference",
            move_tag=lesson_source["lesson_slug"],
            output_path=ref_pose_path,
        )
        frame_count = len(pose_clip["frames"])
    else:
        with open(ref_pose_path, "r", encoding="utf-8") as f:
            pose_clip = json.load(f)
        frame_count = len(pose_clip["frames"])

    # 5. File hashes
    files_map = {
        "video.mp4": sha256_of_file(package_video_path),
        "reference_pose.json": sha256_of_file(ref_pose_path),
        "poster.jpg": sha256_of_file(poster_path),
    }

    # 6. Assemble and validate manifest
    manifest = assemble_manifest(
        lesson_source=lesson_source,
        video_meta=video_meta,
        reference_frame_count=frame_count,
        beat_grid=beat_grid,
        files_sha256=files_map,
    )

    manifest_path = output_dir / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"Package built and validated successfully at {output_dir}", file=sys.stderr)
    return manifest


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description="Build validated Groove Coach lesson package")
    parser.add_argument("lesson", type=Path, help="Lesson source JSON (*.lesson.json)")
    parser.add_argument("video", type=Path, help="Source video file")
    parser.add_argument("output", type=Path, help="Output package directory")
    parser.add_argument("--no-transcode", action="store_true", help="Skip video transcoding")
    parser.add_argument("--no-hands", action="store_true", help="Skip hand landmarking")
    args = parser.parse_args(argv)

    manifest = build_package(
        args.lesson,
        args.video,
        args.output,
        transcode=not args.no_transcode,
        include_hands=not args.no_hands,
    )
    print(f"Package: {manifest['course_slug']}/{manifest['lesson_slug']} v{manifest['package_version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
