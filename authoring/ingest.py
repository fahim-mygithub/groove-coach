"""YouTube & local video ingestion pipeline for Groove Coach authoring (WO yt-ingest).

Policy (orchestrator):
- YouTube-sourced lessons are PRIVATE internal-test material.
- Downloads and outputs live outside the repo (default %LOCALAPPDATA%/groove-authoring/youtube/<video_id>/).
- Never commit media; record source URL + title + channel in provenance; no upload code paths.

Features:
- Download via yt-dlp at <=1080p mp4 H.264/AAC or accept local file path.
- ffprobe metadata (duration, fps, size, rotation, audio).
- Shot-cut detection with ffmpeg select='gt(scene,T)' filter (list of cut timestamps + continuous shots).
- Argon kit for video model: <=480p proxy (original timeline, keeps audio) + 1 fps contact sheet JPEG + ingest.json.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


@dataclass
class IngestResult:
    video_path: Path
    proxy_path: Path
    contact_sheet_path: Path
    json_path: Path
    metadata: Dict[str, Any]
    cuts: List[float]
    shots: List[Dict[str, float]]
    provenance: Dict[str, Any]
    scene_threshold: float

    def to_dict(self) -> Dict[str, Any]:
        return {
            "video_path": str(self.video_path),
            "proxy_path": str(self.proxy_path),
            "contact_sheet_path": str(self.contact_sheet_path),
            "json_path": str(self.json_path),
            "metadata": self.metadata,
            "cuts": self.cuts,
            "shots": self.shots,
            "provenance": self.provenance,
            "scene_threshold": self.scene_threshold,
        }


def get_default_output_dir(video_id: str) -> Path:
    """Return default storage directory outside the repository."""
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        base = Path(local_app_data)
    else:
        # Fallback for Linux / macOS
        base = Path.home() / ".cache"
    return base / "groove-authoring" / "youtube" / video_id


def is_url(url_or_path: str | Path) -> bool:
    """Check if the given string represents a web URL."""
    s = str(url_or_path).strip()
    return bool(re.match(r"^https?://", s, re.IGNORECASE)) or "youtu.be" in s or "youtube.com" in s


def download_youtube(url: str, out_dir: Path) -> Tuple[Path, Dict[str, Any]]:
    """Download YouTube video using yt-dlp at <=1080p mp4 H.264/AAC."""
    try:
        import yt_dlp
    except ImportError as e:
        raise RuntimeError("yt-dlp is required for downloading YouTube videos. Run: pip install yt-dlp") from e

    out_dir.mkdir(parents=True, exist_ok=True)
    ydl_opts: Dict[str, Any] = {
        "format": (
            "bestvideo[height<=1080][ext=mp4][vcodec^=avc]+bestaudio[ext=m4a]/"
            "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best"
        ),
        "outtmpl": str(out_dir / "%(id)s.%(ext)s"),
        "merge_output_format": "mp4",
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=True)
        video_id = info.get("id", "youtube_video")
        title = info.get("title", "")
        channel = info.get("uploader") or info.get("channel") or ""
        source_url = info.get("webpage_url") or url

        prepared = Path(ydl.prepare_filename(info))
        if not prepared.exists():
            mp4_candidate = prepared.with_suffix(".mp4")
            if mp4_candidate.exists():
                prepared = mp4_candidate
            else:
                matches = list(out_dir.glob(f"{video_id}.*"))
                if matches:
                    prepared = matches[0]
                else:
                    raise FileNotFoundError(f"Downloaded video not found for {video_id} in {out_dir}")

    provenance = {
        "source_url": source_url,
        "title": title,
        "channel": channel,
        "video_id": video_id,
    }
    return prepared, provenance


def probe_metadata(video_path: Path) -> Dict[str, Any]:
    """Retrieve video and audio stream metadata using ffprobe."""
    ffprobe_bin = shutil.which("ffprobe")
    if not ffprobe_bin:
        raise RuntimeError("ffprobe not found on PATH; required for metadata extraction.")

    cmd = [
        ffprobe_bin,
        "-v", "error",
        "-show_entries", "stream",
        "-show_entries", "format",
        "-of", "json",
        str(video_path),
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
    data = json.loads(res.stdout)

    v_stream: Dict[str, Any] = {}
    a_stream: Optional[Dict[str, Any]] = None
    for st in data.get("streams", []):
        if st.get("codec_type") == "video" and not v_stream:
            v_stream = st
        elif st.get("codec_type") == "audio" and a_stream is None:
            a_stream = st

    if not v_stream:
        raise ValueError(f"No video stream found in {video_path}")

    width = int(v_stream.get("width", 0))
    height = int(v_stream.get("height", 0))

    r_fps = v_stream.get("r_frame_rate", "30/1")
    if "/" in r_fps:
        n, d = r_fps.split("/")
        fps = float(n) / max(1.0, float(d))
    else:
        fps = float(r_fps) if r_fps else 30.0

    dur_str = v_stream.get("duration") or data.get("format", {}).get("duration") or "0"
    duration_s = float(dur_str)

    # Rotation extraction
    rotation = 0
    if "tags" in v_stream and "rotate" in v_stream["tags"]:
        try:
            rotation = int(float(v_stream["tags"]["rotate"]))
        except (ValueError, TypeError):
            pass
    if not rotation and "side_data_list" in v_stream:
        for sd in v_stream["side_data_list"]:
            if "rotation" in sd:
                try:
                    rotation = int(float(sd["rotation"]))
                    break
                except (ValueError, TypeError):
                    pass

    has_audio = a_stream is not None
    audio_info: Dict[str, Any] = {
        "has_audio": has_audio,
        "codec": a_stream.get("codec_name") if a_stream else None,
        "sample_rate": int(a_stream.get("sample_rate", 0)) if a_stream else 0,
        "channels": int(a_stream.get("channels", 0)) if a_stream else 0,
    }

    return {
        "duration_s": round(duration_s, 3),
        "fps": round(fps, 3),
        "width": width,
        "height": height,
        "size": [width, height],
        "rotation": rotation,
        "has_audio": has_audio,
        "audio": audio_info,
    }


def parse_scene_cuts(stderr_output: str, duration_s: Optional[float] = None) -> List[float]:
    """Parse shot cut timestamps from ffmpeg showinfo stderr."""
    raw_times: List[float] = []
    for match in re.finditer(r"pts_time:([0-9.]+)", stderr_output):
        try:
            t = float(match.group(1))
            raw_times.append(round(t, 3))
        except ValueError:
            continue

    raw_times.sort()
    # Deduplicate timestamps within 0.05s and ignore non-positive or past-duration
    cuts: List[float] = []
    for t in raw_times:
        if t <= 0.01:
            continue
        if duration_s is not None and t >= duration_s - 0.01:
            continue
        if not cuts or (t - cuts[-1]) >= 0.05:
            cuts.append(t)

    return cuts


def shots_from_cuts(cuts: List[float], duration_s: float) -> List[Dict[str, float]]:
    """Convert list of cut timestamps into contiguous shots."""
    dur = round(duration_s, 3)
    if not cuts:
        return [{"start_s": 0.0, "end_s": dur, "duration_s": dur}]

    boundaries = [0.0] + [c for c in cuts if 0.0 < c < dur]
    if not boundaries or boundaries[-1] < dur:
        boundaries.append(dur)

    shots: List[Dict[str, float]] = []
    for i in range(len(boundaries) - 1):
        s = round(boundaries[i], 3)
        e = round(boundaries[i + 1], 3)
        shots.append({
            "start_s": s,
            "end_s": e,
            "duration_s": round(e - s, 3),
        })
    return shots


def detect_shot_cuts(
    video_path: Path,
    scene_threshold: float = 0.4,
    duration_s: Optional[float] = None,
) -> Tuple[List[float], List[Dict[str, float]]]:
    """Detect shot cuts using ffmpeg's select='gt(scene,T)' filter."""
    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError("ffmpeg not found on PATH; required for shot detection.")

    cmd = [
        ffmpeg_bin,
        "-i", str(video_path),
        "-filter:v", f"select='gt(scene,{scene_threshold})',showinfo",
        "-f", "null",
        "-",
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    cuts = parse_scene_cuts(res.stderr, duration_s=duration_s)
    shots = shots_from_cuts(cuts, duration_s=duration_s or 0.0)
    return cuts, shots


def build_proxy(
    video_path: Path,
    proxy_path: Path,
    max_dim: int = 480,
    has_audio: bool = True,
) -> Path:
    """Generate low-res proxy (<=480p, original timeline, keeps audio)."""
    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError("ffmpeg not found on PATH; required for proxy generation.")

    proxy_path.parent.mkdir(parents=True, exist_ok=True)
    scale_filter = f"scale='if(gt(iw,ih),-2,min({max_dim},iw))':'if(gt(iw,ih),min({max_dim},ih),-2)'"

    cmd = [
        ffmpeg_bin,
        "-y",
        "-i", str(video_path),
        "-vf", scale_filter,
        "-c:v", "libx264",
        "-preset", "fast",
        "-crf", "26",
    ]
    if has_audio:
        cmd.extend(["-c:a", "aac", "-b:a", "128k"])
    else:
        cmd.append("-an")

    cmd.extend(["-movflags", "+faststart", str(proxy_path)])
    subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
    return proxy_path


def build_contact_sheet(
    video_path: Path,
    contact_sheet_path: Path,
    duration_s: float,
) -> Path:
    """Generate 1 fps contact sheet JPEG with burned timestamps."""
    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError("ffmpeg not found on PATH; required for contact sheet.")

    contact_sheet_path.parent.mkdir(parents=True, exist_ok=True)
    total_frames = max(1, math.ceil(duration_s))
    cols = min(6, max(1, total_frames))
    rows = math.ceil(total_frames / cols)

    # Primary filter with drawtext timestamp
    drawtext_filter = (
        f"fps=1,scale=160:-1,"
        f"drawtext=text='%{{pts\\:hms}}':box=1:boxcolor=black@0.6:fontcolor=white:fontsize=12:x=5:y=5,"
        f"tile={cols}x{rows}"
    )

    cmd = [
        ffmpeg_bin,
        "-y",
        "-i", str(video_path),
        "-vf", drawtext_filter,
        "-frames:v", "1",
        "-update", "1",
        str(contact_sheet_path),
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    if res.returncode != 0:
        # Fallback if drawtext fails (e.g. minimal fontconfig)
        fallback_filter = f"fps=1,scale=160:-1,tile={cols}x{rows}"
        fallback_cmd = [
            ffmpeg_bin,
            "-y",
            "-i", str(video_path),
            "-vf", fallback_filter,
            "-frames:v", "1",
            "-update", "1",
            str(contact_sheet_path),
        ]
        subprocess.run(fallback_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)

    return contact_sheet_path


def ingest(
    url_or_path: str | Path,
    out_dir: Optional[Path | str] = None,
    scene_threshold: float = 0.4,
    proxy_max_dim: int = 480,
) -> IngestResult:
    """Ingest a YouTube URL or local video file into the authoring workspace.

    Args:
        url_or_path: YouTube URL or local file path.
        out_dir: Target output directory outside repo. Defaults to %LOCALAPPDATA%/groove-authoring/youtube/<id>.
        scene_threshold: Threshold T for ffmpeg select='gt(scene,T)' shot cut detection.
        proxy_max_dim: Maximum dimension for proxy video (default 480).

    Returns:
        IngestResult containing paths and metadata.
    """
    raw_target = str(url_or_path).strip()
    if is_url(raw_target):
        # Temporary resolution of ID if possible, otherwise yt-dlp will provide it
        url = raw_target
        temp_id = "downloading"
        target_dir = Path(out_dir) if out_dir else get_default_output_dir(temp_id)
        video_path, provenance = download_youtube(url, target_dir)
        video_id = provenance["video_id"]
        # If default dir was used with temp_id, move to permanent dir if different
        if not out_dir and temp_id != video_id:
            final_dir = get_default_output_dir(video_id)
            final_dir.parent.mkdir(parents=True, exist_ok=True)
            if target_dir.exists() and target_dir != final_dir:
                if final_dir.exists():
                    shutil.rmtree(final_dir)
                target_dir.rename(final_dir)
                target_dir = final_dir
                video_path = target_dir / video_path.name
        else:
            target_dir = video_path.parent
    else:
        video_path = Path(raw_target).resolve()
        if not video_path.exists():
            raise FileNotFoundError(f"Input video file not found: {video_path}")
        video_id = video_path.stem
        target_dir = Path(out_dir) if out_dir else get_default_output_dir(video_id)
        target_dir.mkdir(parents=True, exist_ok=True)
        provenance = {
            "source_url": str(video_path),
            "title": video_path.name,
            "channel": None,
            "video_id": video_id,
        }

    # Extract metadata
    metadata = probe_metadata(video_path)
    duration_s = float(metadata.get("duration_s", 0.0))
    has_audio = bool(metadata.get("has_audio", False))

    # Detect shot cuts
    cuts, shots = detect_shot_cuts(video_path, scene_threshold=scene_threshold, duration_s=duration_s)

    # Low-res proxy
    proxy_path = target_dir / "proxy.mp4"
    build_proxy(video_path, proxy_path, max_dim=proxy_max_dim, has_audio=has_audio)

    # Contact sheet JPEG (1 fps with burned timestamps)
    contact_sheet_path = target_dir / "contact_sheet.jpg"
    build_contact_sheet(video_path, contact_sheet_path, duration_s=duration_s)

    # Ingest JSON
    json_path = target_dir / "ingest.json"
    result = IngestResult(
        video_path=video_path,
        proxy_path=proxy_path,
        contact_sheet_path=contact_sheet_path,
        json_path=json_path,
        metadata=metadata,
        cuts=cuts,
        shots=shots,
        provenance=provenance,
        scene_threshold=scene_threshold,
    )

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(result.to_dict(), f, indent=2)

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest video (YouTube URL or local file) for lesson authoring.")
    parser.add_argument("url_or_path", help="YouTube URL or local video path")
    parser.add_argument("--out-dir", "-o", default=None, help="Output directory outside the repo")
    parser.add_argument("--scene-threshold", "-t", type=float, default=0.4, help="Scene cut detection threshold")
    parser.add_argument("--proxy-max-dim", type=int, default=480, help="Max dimension for proxy video")

    args = parser.parse_args()
    res = ingest(
        url_or_path=args.url_or_path,
        out_dir=Path(args.out_dir) if args.out_dir else None,
        scene_threshold=args.scene_threshold,
        proxy_max_dim=args.proxy_max_dim,
    )
    print(f"Ingest complete:")
    print(f"  Video:         {res.video_path}")
    print(f"  Proxy:         {res.proxy_path}")
    print(f"  Contact Sheet: {res.contact_sheet_path}")
    print(f"  Ingest JSON:   {res.json_path}")
    print(f"  Duration:      {res.metadata.get('duration_s')}s, FPS: {res.metadata.get('fps')}")
    print(f"  Detected cuts: {len(res.cuts)} ({len(res.shots)} continuous shots)")


if __name__ == "__main__":
    main()
