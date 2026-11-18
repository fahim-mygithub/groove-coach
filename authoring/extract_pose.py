"""MediaPipe Pose and Hand landmark extraction for Groove Coach authoring pipeline (spec §2.1, WO-1C).

Extracts MediaPipe PoseLandmarker in VIDEO mode (num_poses=1, model pose_landmarker_full) and
HandLandmarker, both pinned by sha256. Maps to canonical skeleton groove.canonical/1, smooths with
One Euro filter, and writes reference_pose.json as a PoseClip.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import sys
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from groove_eval.canonical_skeleton import to_canonical
from groove_eval.one_euro import OneEuroLandmarkBank

# Pinned model specifications
POSE_MODEL_NAME = "pose_landmarker_full"
POSE_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/"
    "pose_landmarker_full.task"
)
POSE_MODEL_SHA256 = "5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1"

HAND_MODEL_NAME = "hand_landmarker"
HAND_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/"
    "hand_landmarker.task"
)
HAND_MODEL_SHA256 = "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"

MEDIAPIPE_PYTHON_VERSION = "1.2.0"

# Smoothing defaults (matching groove_config.json)
DEFAULT_SMOOTHING_PARAMS = {
    "min_cutoff": 1.2,
    "beta": 3.0,
    "d_cutoff": 1.0,
}


def sha256_of_file(path: Path) -> str:
    """Compute sha256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def ensure_model(model_name: str, cache_dir: Optional[Path] = None) -> Path:
    """Download and verify model task file by sha256 if not present."""
    if model_name == POSE_MODEL_NAME:
        url = POSE_MODEL_URL
        expected_sha = POSE_MODEL_SHA256
        filename = "pose_landmarker_full.task"
    elif model_name == HAND_MODEL_NAME:
        url = HAND_MODEL_URL
        expected_sha = HAND_MODEL_SHA256
        filename = "hand_landmarker.task"
    else:
        raise ValueError(f"Unknown model name: {model_name}")

    if cache_dir is None:
        cache_dir = Path(os.path.expanduser("~/.cache/groove-models"))
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / filename

    if target.exists():
        actual_sha = sha256_of_file(target)
        if actual_sha == expected_sha:
            return target
        print(f"Warning: sha256 mismatch for existing {target}, re-downloading...", file=sys.stderr)
        target.unlink()

    tmp_target = cache_dir / f"{filename}.tmp"
    print(f"Fetching {model_name} from {url}...", file=sys.stderr)
    urllib.request.urlretrieve(url, tmp_target)

    actual_sha = sha256_of_file(tmp_target)
    if actual_sha != expected_sha:
        tmp_target.unlink()
        raise ValueError(
            f"sha256 mismatch for {model_name}: expected {expected_sha}, got {actual_sha}"
        )

    shutil.move(str(tmp_target), str(target))
    return target


def round_frame_coordinates(frame: Dict[str, Any], decimals: int = 4) -> Dict[str, Any]:
    """Round joint coordinates and confidences to specified decimals (spec §2.2)."""
    out: Dict[str, Any] = {"t": round(float(frame["t"]), decimals)}

    if "joints" in frame:
        out["joints"] = {
            name: [round(float(v), decimals) for v in pt]
            for name, pt in frame["joints"].items()
        }

    if "confidences" in frame:
        out["confidences"] = {
            name: round(float(c), decimals)
            for name, c in frame["confidences"].items()
        }

    if "hands" in frame:
        out["hands"] = {
            side: [[round(float(v), decimals) for v in pt] for pt in pts]
            for side, pts in frame["hands"].items()
        }

    return out


def smooth_canonical_frames(
    frames: Sequence[Dict[str, Any]],
    params: Optional[Mapping[str, float]] = None,
) -> List[Dict[str, Any]]:
    """One Euro filter smoothing of canonical joint positions."""
    p = params or DEFAULT_SMOOTHING_PARAMS
    bank = OneEuroLandmarkBank(
        min_cutoff=float(p["min_cutoff"]),
        beta=float(p["beta"]),
        d_cutoff=float(p["d_cutoff"]),
    )
    out: List[Dict[str, Any]] = []
    for f in frames:
        valid_joints = {
            k: v for k, v in f.get("joints", {}).items()
            if v is not None and len(v) >= 3
        }
        filtered = bank.filter(valid_joints, float(f["t"]))
        new_frame = dict(f)
        new_joints = dict(f.get("joints", {}))
        new_joints.update(filtered)
        new_frame["joints"] = new_joints
        out.append(new_frame)
    return out


def extract_pose_clip(
    video_path: Path,
    *,
    pose_model_path: Optional[Path] = None,
    hand_model_path: Optional[Path] = None,
    include_hands: bool = True,
    smooth: bool = True,
    smoothing_params: Optional[Mapping[str, float]] = None,
    bpm: float = 112.5,
    beat_times: Optional[Sequence[float]] = None,
    clip_id: str = "img4941-routine",
    move_tag: str = "routine",
    output_path: Optional[Path] = None,
) -> Dict[str, Any]:
    """Extract canonical skeleton PoseClip from a video using MediaPipe Pose + Hand landmarker."""
    try:
        import cv2
        import mediapipe as mp
        from mediapipe.tasks import python
        from mediapipe.tasks.python import vision
    except ImportError as e:
        raise RuntimeError(
            f"extract_pose_clip requires opencv and mediapipe: {e}. "
            "Install requirements via `pip install -r authoring/requirements.txt`."
        )

    video_path = Path(video_path)
    if not video_path.exists():
        raise FileNotFoundError(f"Video not found: {video_path}")

    # Ensure models exist and match sha256
    if pose_model_path is None:
        pose_model_path = ensure_model(POSE_MODEL_NAME)
    else:
        pose_sha = sha256_of_file(pose_model_path)
        if pose_sha != POSE_MODEL_SHA256:
            raise ValueError(f"Pose model sha256 mismatch: expected {POSE_MODEL_SHA256}, got {pose_sha}")

    if include_hands:
        if hand_model_path is None:
            hand_model_path = ensure_model(HAND_MODEL_NAME)
        else:
            hand_sha = sha256_of_file(hand_model_path)
            if hand_sha != HAND_MODEL_SHA256:
                raise ValueError(f"Hand model sha256 mismatch: expected {HAND_MODEL_SHA256}, got {hand_sha}")

    # Initialize PoseLandmarker in VIDEO mode
    pose_base_options = python.BaseOptions(
        model_asset_path=str(pose_model_path),
        delegate=python.BaseOptions.Delegate.CPU,
    )
    pose_options = vision.PoseLandmarkerOptions(
        base_options=pose_base_options,
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
    )
    pose_detector = vision.PoseLandmarker.create_from_options(pose_options)

    # Initialize HandLandmarker in VIDEO mode if requested
    hand_detector = None
    if include_hands and hand_model_path is not None:
        hand_base_options = python.BaseOptions(
            model_asset_path=str(hand_model_path),
            delegate=python.BaseOptions.Delegate.CPU,
        )
        hand_options = vision.HandLandmarkerOptions(
            base_options=hand_base_options,
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
        )
        hand_detector = vision.HandLandmarker.create_from_options(hand_options)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Could not open video file: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    aspect = float(width) / float(height) if height > 0 else 1.0

    raw_frames: List[Dict[str, Any]] = []
    frame_idx = 0

    while cap.isOpened():
        ret, frame_bgr = cap.read()
        if not ret:
            break

        timestamp_ms = int(round(frame_idx * 1000.0 / fps))
        t = frame_idx / float(fps)

        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

        pose_result = pose_detector.detect_for_video(mp_image, timestamp_ms)

        hands_data = None
        if hand_detector is not None:
            hand_result = hand_detector.detect_for_video(mp_image, timestamp_ms)
            if hand_result.hand_landmarks:
                hands_data = []
                for h_idx in range(len(hand_result.hand_landmarks)):
                    w_lm = [[lm.x, lm.y, lm.z] for lm in hand_result.hand_world_landmarks[h_idx]]
                    i_lm = [[lm.x, lm.y, lm.z] for lm in hand_result.hand_landmarks[h_idx]]
                    hands_data.append({"world_landmarks": w_lm, "image_landmarks": i_lm})

        if pose_result.pose_world_landmarks:
            world_landmarks = [[lm.x, lm.y, lm.z] for lm in pose_result.pose_world_landmarks[0]]
            visibility = [lm.visibility for lm in pose_result.pose_landmarks[0]]
            image_landmarks = [[lm.x, lm.y, lm.z] for lm in pose_result.pose_landmarks[0]]

            canonical_frame = to_canonical(
                world_landmarks,
                visibility,
                hands=hands_data if hands_data else None,
                t=t,
                image_landmarks=image_landmarks if hands_data else None,
                image_aspect=aspect,
            )
            raw_frames.append(canonical_frame)

        frame_idx += 1

    cap.release()
    pose_detector.close()
    if hand_detector is not None:
        hand_detector.close()

    # Apply One Euro smoothing if requested
    processed_frames = smooth_canonical_frames(raw_frames, smoothing_params) if smooth else raw_frames

    # Round coordinates to 4 decimals for compactness
    final_frames = [round_frame_coordinates(f, 4) for f in processed_frames]

    # Assemble PoseClip shape
    pose_clip: Dict[str, Any] = {
        "clip_id": clip_id,
        "move_tag": move_tag,
        "bpm": float(bpm),
        "beat_times": list(beat_times) if beat_times is not None else [],
        "gravity_vector": [0.0, -1.0, 0.0],
        "mirrored": False,
        "audio_latency_ms": 0.0,
        "speed_pct": 100,
        "frames": final_frames,
    }

    if output_path is not None:
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(pose_clip, f, indent=2)

    return pose_clip


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description="Extract canonical PoseClip from video using MediaPipe")
    parser.add_argument("video", type=Path, help="Input video file path")
    parser.add_argument("--out", type=Path, default=Path("reference_pose.json"), help="Output JSON path")
    parser.add_argument("--bpm", type=float, default=112.5, help="BPM")
    parser.add_argument("--no-hands", action="store_true", help="Disable hand landmarker")
    parser.add_argument("--no-smooth", action="store_true", help="Disable One Euro smoothing")
    args = parser.parse_args(argv)

    print(f"Extracting pose from {args.video} -> {args.out}...")
    clip = extract_pose_clip(
        args.video,
        include_hands=not args.no_hands,
        smooth=not args.no_smooth,
        bpm=args.bpm,
        output_path=args.out,
    )
    print(f"Extracted {len(clip['frames'])} frames successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
