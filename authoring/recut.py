"""Recut video according to cut plan with crop, flip, concat, and timemap (WO yt-ingest).

Features:
- Apply cut plan: list of {src_start_s, src_end_s} + optional crop box {x,y,w,h} in source px + optional horizontal flip.
- Concat with ffmpeg in order, re-timed from 0.
- Crop to target dancer so MediaPipe num_poses=1 locks on the right person.
- Fixed timemap shape: [{"out_start_s": float, "src_start_s": float, "dur_s": float}, ...]
- Bidirectional timemap lookup: out_to_src and src_to_out.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union


def parse_crop_box(crop: Any) -> Optional[Dict[str, int]]:
    """Parse and validate crop box structure."""
    if crop is None:
        return None
    if isinstance(crop, (list, tuple)) and len(crop) == 4:
        x, y, w, h = crop
    elif isinstance(crop, dict):
        x = crop.get("x", 0)
        y = crop.get("y", 0)
        w = crop.get("w") if "w" in crop else crop.get("width")
        h = crop.get("h") if "h" in crop else crop.get("height")
        if w is None or h is None:
            raise ValueError(f"Crop dictionary must specify width ('w' or 'width') and height ('h' or 'height'): {crop}")
    else:
        raise ValueError(f"Unsupported crop format: {crop}")

    x = int(x)
    y = int(y)
    w = int(w)
    h = int(h)

    # Ensure even dimensions for H.264 / yuv420p
    w = w - (w % 2)
    h = h - (h % 2)

    return {"x": x, "y": y, "w": w, "h": h}


def build_crop_flip_filter(crop: Optional[Dict[str, int]] = None, hflip: bool = False) -> str:
    """Build ffmpeg video filter string for crop and horizontal flip."""
    filters: List[str] = []
    if crop:
        filters.append(f"crop={crop['w']}:{crop['h']}:{crop['x']}:{crop['y']}")
    if hflip:
        filters.append("hflip")
    return ",".join(filters)


def validate_cut_plan(
    cuts: List[Dict[str, Any]],
    duration_s: Optional[float] = None,
    width: Optional[int] = None,
    height: Optional[int] = None,
) -> None:
    """Validate cut plan consistency, ranges, crop bounds, and ensure no overlaps."""
    if not cuts:
        raise ValueError("Cut plan must contain at least one cut.")

    for i, c in enumerate(cuts):
        start = c.get("src_start_s")
        end = c.get("src_end_s")
        if start is None or end is None:
            raise ValueError(f"Cut {i} is missing 'src_start_s' or 'src_end_s': {c}")

        if start < 0.0:
            raise ValueError(f"Cut {i} has negative start time: {start}")
        if end <= start:
            raise ValueError(f"Cut {i} has non-positive duration: start={start}, end={end}")

        if duration_s is not None and end > duration_s + 0.05:
            raise ValueError(f"Cut {i} end time {end} exceeds source duration {duration_s}")

        crop = c.get("crop")
        if crop:
            if crop["x"] < 0 or crop["y"] < 0:
                raise ValueError(f"Cut {i} crop offsets must be non-negative: {crop}")
            if crop["w"] <= 0 or crop["h"] <= 0:
                raise ValueError(f"Cut {i} crop dimensions must be positive: {crop}")
            if width is not None and (crop["x"] + crop["w"] > width):
                raise ValueError(f"Cut {i} crop exceeds video width ({width}): {crop}")
            if height is not None and (crop["y"] + crop["h"] > height):
                raise ValueError(f"Cut {i} crop exceeds video height ({height}): {crop}")

    # Check for overlaps
    for i in range(len(cuts)):
        s1 = cuts[i]["src_start_s"]
        e1 = cuts[i]["src_end_s"]
        for j in range(i + 1, len(cuts)):
            s2 = cuts[j]["src_start_s"]
            e2 = cuts[j]["src_end_s"]
            # Two open intervals (s1, e1) and (s2, e2) overlap if max(s1, s2) < min(e1, e2)
            if max(s1, s2) < min(e1, e2):
                raise ValueError(
                    f"Overlapping cuts detected in cut plan: cut {i} [{s1}, {e1}] and cut {j} [{s2}, {e2}]"
                )


def build_timemap(cuts: List[Dict[str, Any]]) -> List[Dict[str, float]]:
    """Build fixed shape timemap: [{"out_start_s": float, "src_start_s": float, "dur_s": float}, ...]."""
    timemap: List[Dict[str, float]] = []
    out_pos = 0.0
    for c in cuts:
        start = float(c["src_start_s"])
        end = float(c["src_end_s"])
        dur = round(end - start, 4)
        timemap.append({
            "out_start_s": round(out_pos, 4),
            "src_start_s": round(start, 4),
            "dur_s": dur,
        })
        out_pos += dur
    return timemap


def out_to_src(out_t: float, timemap: List[Dict[str, float]]) -> float:
    """Map output video timestamp back to original source timestamp."""
    if not timemap:
        return out_t

    # Find the corresponding piece
    for piece in timemap:
        s_out = piece["out_start_s"]
        dur = piece["dur_s"]
        if s_out <= out_t <= s_out + dur:
            offset = out_t - s_out
            return round(piece["src_start_s"] + offset, 4)

    # Beyond last piece
    last = timemap[-1]
    offset = out_t - last["out_start_s"]
    return round(last["src_start_s"] + offset, 4)


def src_to_out(src_t: float, timemap: List[Dict[str, float]]) -> Optional[float]:
    """Map original source timestamp to output video timestamp, or None if pruned."""
    for piece in timemap:
        s_src = piece["src_start_s"]
        dur = piece["dur_s"]
        if s_src <= src_t <= s_src + dur:
            offset = src_t - s_src
            return round(piece["out_start_s"] + offset, 4)
    return None


def build_filter_complex(cuts: List[Dict[str, Any]], has_audio: bool = True) -> str:
    """Construct ffmpeg filter_complex string to trim, crop, flip, and concatenate pieces."""
    parts: List[str] = []
    for i, c in enumerate(cuts):
        v_filters = [
            f"trim=start={c['src_start_s']}:end={c['src_end_s']}",
            "setpts=PTS-STARTPTS",
        ]
        cf = build_crop_flip_filter(c.get("crop"), c.get("hflip", False))
        if cf:
            v_filters.append(cf)
        parts.append(f"[0:v]{','.join(v_filters)}[v{i}]")

        if has_audio:
            a_filters = [
                f"atrim=start={c['src_start_s']}:end={c['src_end_s']}",
                "asetpts=PTS-STARTPTS",
            ]
            parts.append(f"[0:a]{','.join(a_filters)}[a{i}]")

    n = len(cuts)
    if has_audio:
        concat_ins = "".join(f"[v{i}][a{i}]" for i in range(n))
        parts.append(f"{concat_ins}concat=n={n}:v=1:a=1[outv][outa]")
    else:
        concat_ins = "".join(f"[v{i}]" for i in range(n))
        parts.append(f"{concat_ins}concat=n={n}:v=1:a=0[outv]")

    return ";".join(parts)


def parse_cut_plan(plan_data: Any) -> List[Dict[str, Any]]:
    """Normalize input cut plan dict or list into canonical cut entries."""
    if isinstance(plan_data, list):
        raw_cuts = plan_data
        global_crop = None
        global_hflip = False
    elif isinstance(plan_data, dict):
        raw_cuts = plan_data.get("cuts") or plan_data.get("segments") or plan_data.get("pieces")
        if raw_cuts is None:
            # Single cut plan defined at top-level
            if "src_start_s" in plan_data or "start_s" in plan_data:
                raw_cuts = [plan_data]
            else:
                raise ValueError("Cut plan dictionary must contain a 'cuts' list.")
        global_crop = parse_crop_box(plan_data.get("crop"))
        global_hflip = bool(
            plan_data.get("hflip", False)
            or plan_data.get("horizontal_flip", False)
            or (plan_data.get("flip") == "horizontal")
        )
    else:
        raise ValueError(f"Unexpected cut plan structure: {type(plan_data)}")

    normalized_cuts: List[Dict[str, Any]] = []
    for item in raw_cuts:
        start = item.get("src_start_s") if "src_start_s" in item else item.get("start_s", item.get("start"))
        end = item.get("src_end_s") if "src_end_s" in item else item.get("end_s", item.get("end"))
        if start is None or end is None:
            raise ValueError(f"Cut missing start or end: {item}")

        item_crop = parse_crop_box(item.get("crop")) if item.get("crop") is not None else global_crop
        item_hflip = (
            bool(
                item.get("hflip", False)
                or item.get("horizontal_flip", False)
                or (item.get("flip") == "horizontal")
            )
            if "hflip" in item or "horizontal_flip" in item or "flip" in item
            else global_hflip
        )

        normalized_cuts.append({
            "src_start_s": float(start),
            "src_end_s": float(end),
            "crop": item_crop,
            "hflip": item_hflip,
        })

    return normalized_cuts


def recut(
    ingest: Union[Any, str, Path, Dict[str, Any]],
    cut_plan: Union[str, Path, Dict[str, Any], List[Dict[str, Any]]],
    out_path: Optional[Union[str, Path]] = None,
) -> Path:
    """Apply cut plan to ingested video with ffmpeg, save timemap, and return output video path.

    Args:
        ingest: IngestResult instance, Path to ingest.json, loaded dict, or video file path.
        cut_plan: Path to cut_plan.json, loaded dict, or list of cuts.
        out_path: Optional output video path. Defaults to <ingest_dir>/recut.mp4.

    Returns:
        Path to the recut video.
    """
    # 1. Resolve source video path and metadata
    metadata: Dict[str, Any] = {}
    default_dir: Path = Path.cwd()

    if isinstance(ingest, (str, Path)):
        p = Path(ingest).resolve()
        if p.suffix.lower() == ".json":
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
            video_path = Path(data["video_path"]).resolve()
            metadata = data.get("metadata", {})
            default_dir = p.parent
        else:
            video_path = p
            default_dir = p.parent
    elif isinstance(ingest, dict):
        video_path = Path(ingest["video_path"]).resolve()
        metadata = ingest.get("metadata", {})
        default_dir = video_path.parent
    elif hasattr(ingest, "video_path"):
        video_path = Path(ingest.video_path).resolve()
        metadata = getattr(ingest, "metadata", {})
        default_dir = video_path.parent
    else:
        raise ValueError(f"Unsupported ingest reference type: {type(ingest)}")

    if not video_path.exists():
        raise FileNotFoundError(f"Source video for recut not found: {video_path}")

    # 2. Resolve cut plan
    if isinstance(cut_plan, (str, Path)):
        plan_p = Path(cut_plan).resolve()
        with open(plan_p, "r", encoding="utf-8") as f:
            plan_data = json.load(f)
    else:
        plan_data = cut_plan

    cuts = parse_cut_plan(plan_data)

    # 3. Plan validation
    duration_s = metadata.get("duration_s")
    width = metadata.get("width")
    height = metadata.get("height")
    validate_cut_plan(cuts, duration_s=duration_s, width=width, height=height)

    # 4. Resolve output paths
    if out_path:
        out_video_path = Path(out_path).resolve()
    else:
        out_video_path = default_dir / "recut.mp4"

    out_video_path.parent.mkdir(parents=True, exist_ok=True)
    timemap_path = out_video_path.with_name(f"{out_video_path.stem}.timemap.json")
    generic_timemap_path = out_video_path.parent / "timemap.json"

    # 5. Build fixed timemap
    timemap = build_timemap(cuts)
    with open(timemap_path, "w", encoding="utf-8") as f:
        json.dump(timemap, f, indent=2)
    if generic_timemap_path != timemap_path:
        with open(generic_timemap_path, "w", encoding="utf-8") as f:
            json.dump(timemap, f, indent=2)

    # 6. Execute ffmpeg
    ffmpeg_bin = shutil.which("ffmpeg")
    if not ffmpeg_bin:
        raise RuntimeError("ffmpeg not found on PATH; required for recutting video.")

    has_audio = metadata.get("has_audio", True)
    filter_complex = build_filter_complex(cuts, has_audio=has_audio)

    cmd = [
        ffmpeg_bin,
        "-y",
        "-i", str(video_path),
        "-filter_complex", filter_complex,
        "-map", "[outv]",
    ]
    if has_audio:
        cmd.extend(["-map", "[outa]"])

    cmd.extend([
        "-c:v", "libx264",
        "-preset", "fast",
        "-crf", "20",
    ])
    if has_audio:
        cmd.extend(["-c:a", "aac", "-b:a", "128k"])

    cmd.extend(["-movflags", "+faststart", str(out_video_path)])

    subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
    return out_video_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Recut video using cut plan with crop, flip, and timemap.")
    parser.add_argument("ingest_json", help="Path to ingest.json (or video path)")
    parser.add_argument("cut_plan_json", help="Path to cut_plan.json")
    parser.add_argument("--out", "-o", default=None, help="Output recut video path")

    args = parser.parse_args()
    out_video = recut(
        ingest=args.ingest_json,
        cut_plan=args.cut_plan_json,
        out_path=args.out,
    )
    timemap_path = out_video.with_name(f"{out_video.stem}.timemap.json")
    print(f"Recut complete:")
    print(f"  Recut Video: {out_video}")
    print(f"  Timemap:     {timemap_path}")


if __name__ == "__main__":
    main()
