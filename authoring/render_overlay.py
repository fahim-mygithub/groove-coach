"""Debug skeleton overlay video renderer for Groove Coach authoring (spec §2.1, WO-1C).

Renders debug_overlay.mp4 with the skeleton (and hands) drawn over the dancer video,
displaying time, beat grid counts, and segment labels for the owner to eyeball.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from authoring.extract_pose import (
    HAND_MODEL_NAME,
    POSE_MODEL_NAME,
    ensure_model,
)

# MediaPipe 33-point body connections
POSE_CONNECTIONS = (
    # Torso and shoulders
    (11, 12), (11, 23), (12, 24), (23, 24),
    # Left arm
    (11, 13), (13, 15), (15, 17), (15, 19), (15, 21), (17, 19),
    # Right arm
    (12, 14), (14, 16), (16, 18), (16, 20), (16, 22), (18, 20),
    # Left leg & foot
    (23, 25), (25, 27), (27, 29), (29, 31), (27, 31),
    # Right leg & foot
    (24, 26), (26, 28), (28, 30), (30, 32), (28, 32),
)

# MediaPipe 21-point hand connections
HAND_CONNECTIONS = (
    # Palm base
    (0, 1), (0, 5), (0, 17), (5, 9), (9, 13), (13, 17),
    # Thumb
    (1, 2), (2, 3), (3, 4),
    # Index
    (5, 6), (6, 7), (7, 8),
    # Middle
    (9, 10), (10, 11), (11, 12),
    # Ring
    (13, 14), (14, 15), (15, 16),
    # Pinky
    (17, 18), (18, 19), (19, 20),
)


def draw_skeleton_on_frame(
    frame_bgr: Any,
    pose_landmarks: Any,
    hand_landmarks_list: Optional[Sequence[Any]] = None,
    text_info: Optional[str] = None,
) -> Any:
    """Draw MediaPipe skeleton landmarks and limb bones onto an OpenCV BGR frame."""
    import cv2
    img = frame_bgr.copy()
    h, w = img.shape[:2]

    # Draw body bones
    if pose_landmarks:
        for idx1, idx2 in POSE_CONNECTIONS:
            lm1 = pose_landmarks[idx1]
            lm2 = pose_landmarks[idx2]
            if lm1.visibility > 0.4 and lm2.visibility > 0.4:
                pt1 = (int(lm1.x * w), int(lm1.y * h))
                pt2 = (int(lm2.x * w), int(lm2.y * h))
                cv2.line(img, pt1, pt2, (0, 255, 128), 3, cv2.LINE_AA)

        # Draw body joints
        for idx, lm in enumerate(pose_landmarks):
            if lm.visibility > 0.4:
                pt = (int(lm.x * w), int(lm.y * h))
                # Distinct highlight for feet (27-32) and wrists (15, 16)
                if idx in (15, 16):
                    cv2.circle(img, pt, 6, (0, 165, 255), -1, cv2.LINE_AA)
                elif idx in (27, 28, 29, 30, 31, 32):
                    cv2.circle(img, pt, 5, (255, 200, 0), -1, cv2.LINE_AA)
                else:
                    cv2.circle(img, pt, 4, (0, 255, 255), -1, cv2.LINE_AA)

    # Draw hands
    if hand_landmarks_list:
        for hands in hand_landmarks_list:
            for idx1, idx2 in HAND_CONNECTIONS:
                lm1 = hands[idx1]
                lm2 = hands[idx2]
                pt1 = (int(lm1.x * w), int(lm1.y * h))
                pt2 = (int(lm2.x * w), int(lm2.y * h))
                cv2.line(img, pt1, pt2, (255, 0, 255), 2, cv2.LINE_AA)
            for lm in hands:
                pt = (int(lm.x * w), int(lm.y * h))
                cv2.circle(img, pt, 3, (255, 128, 255), -1, cv2.LINE_AA)

    # Text overlay
    if text_info:
        cv2.putText(
            img,
            text_info,
            (20, 45),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.85,
            (0, 0, 0),
            4,
            cv2.LINE_AA,
        )
        cv2.putText(
            img,
            text_info,
            (20, 45),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.85,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )

    return img


def render_overlay_video(
    video_path: Path,
    output_path: Path,
    *,
    manifest_data: Optional[Mapping[str, Any]] = None,
    include_hands: bool = True,
) -> Path:
    """Render debug_overlay.mp4 with skeleton overlayed on source video."""
    try:
        import cv2
        import mediapipe as mp
        from mediapipe.tasks import python
        from mediapipe.tasks.python import vision
    except ImportError as e:
        raise RuntimeError(f"render_overlay_video requires opencv and mediapipe: {e}")

    video_path = Path(video_path)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    pose_model_path = ensure_model(POSE_MODEL_NAME)
    hand_model_path = ensure_model(HAND_MODEL_NAME) if include_hands else None

    pose_options = vision.PoseLandmarkerOptions(
        base_options=python.BaseOptions(model_asset_path=str(pose_model_path), delegate=python.BaseOptions.Delegate.CPU),
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
    )
    pose_detector = vision.PoseLandmarker.create_from_options(pose_options)

    hand_detector = None
    if hand_model_path is not None:
        hand_options = vision.HandLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_path=str(hand_model_path), delegate=python.BaseOptions.Delegate.CPU),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
        )
        hand_detector = vision.HandLandmarker.create_from_options(hand_options)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Could not open video {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    # Beat and segment lookup helper
    beats = manifest_data.get("beat_grid", {}).get("beats", []) if manifest_data else []
    segments = manifest_data.get("segments", []) if manifest_data else []

    def get_info_text(t: float, frame_idx: int) -> str:
        # Find active segment
        cur_seg = "Intro"
        for s in segments:
            if s.get("kind") != "full_run" and s["start_s"] <= t <= s["end_s"]:
                cur_seg = f"Seg {s['id']}: {s['title'][:18]}"
                break

        # Find current beat
        cur_beat = ""
        for b in beats:
            if abs(t - b["t"]) <= 0.08:
                cur_beat = f" [Count {b['count']} - Downbeat!]" if b["count"] == 1 else f" [Count {b['count']}]"
                break

        return f"t={t:.2f}s #{frame_idx} | {cur_seg}{cur_beat}"

    with tempfile.TemporaryDirectory() as tmpdir:
        temp_video = Path(tmpdir) / "temp_overlay.mp4"
        fourcc = cv2.VideoWriter_fourcc(*"mp4v")
        writer = cv2.VideoWriter(str(temp_video), fourcc, fps, (width, height))

        frame_idx = 0
        while cap.isOpened():
            ret, frame_bgr = cap.read()
            if not ret:
                break

            ts_ms = int(round(frame_idx * 1000.0 / fps))
            t = frame_idx / float(fps)

            rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

            pose_res = pose_detector.detect_for_video(mp_image, ts_ms)
            hand_res = hand_detector.detect_for_video(mp_image, ts_ms) if hand_detector else None

            pose_lms = pose_res.pose_landmarks[0] if pose_res.pose_landmarks else None
            hand_lms = hand_res.hand_landmarks if (hand_res and hand_res.hand_landmarks) else None

            overlay_frame = draw_skeleton_on_frame(
                frame_bgr,
                pose_lms,
                hand_lms,
                text_info=get_info_text(t, frame_idx),
            )
            writer.write(overlay_frame)
            frame_idx += 1

        cap.release()
        writer.release()
        pose_detector.close()
        if hand_detector:
            hand_detector.close()

        # Remux with audio via ffmpeg if available
        ffmpeg_bin = shutil.which("ffmpeg")
        if ffmpeg_bin:
            cmd = [
                ffmpeg_bin,
                "-y",
                "-i", str(temp_video),
                "-i", str(video_path),
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-map", "0:v:0",
                "-map", "1:a:0?",
                "-shortest",
                "-movflags", "+faststart",
                str(output_path),
            ]
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        else:
            shutil.copy2(temp_video, output_path)

    return output_path


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description="Render skeleton overlay debug video")
    parser.add_argument("video", type=Path, help="Input video path")
    parser.add_argument("--out", type=Path, default=Path("debug_overlay.mp4"), help="Output video path")
    parser.add_argument("--manifest", type=Path, default=None, help="Optional manifest or lesson source JSON")
    parser.add_argument("--no-hands", action="store_true", help="Skip hand landmarks")
    args = parser.parse_args(argv)

    manifest_data = None
    if args.manifest and args.manifest.exists():
        import json
        with open(args.manifest, "r", encoding="utf-8") as f:
            manifest_data = json.load(f)

    print(f"Rendering skeleton overlay: {args.video} -> {args.out}...")
    render_overlay_video(args.video, args.out, manifest_data=manifest_data, include_hands=not args.no_hands)
    print(f"Rendered overlay: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
