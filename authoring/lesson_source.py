"""Argon video breakdown validation and lesson source conversion (WO: argon-lesson-source).

Argon (Gemini video model) analyzes a dance choreography video and returns a machine-checkable
breakdown (conforming to schemas/argon_breakdown.schema.json).

This module:
1. Validates the breakdown against its JSON Schema and domain cross-checks:
   - Target dancer existence.
   - Cut plan intervals within video duration, monotonic, and non-overlapping.
   - Shots within duration.
   - Segments wholly contained within single usable shots (no cuts across segments).
   - Segments wholly contained within kept cut_plan intervals.
   - Segments ascending in time.
   - Segment boundaries aligned to the BPM grid (within +-40 ms tolerance).
   - Teach order validity.
2. Converts the breakdown to Groove Coach lesson source format (as in img4941.lesson.json)
   using a timemap (output timeline -> source timeline) from recutting:
   timemap is a list of {"out_start_s": float, "src_start_s": float, "dur_s": float}.
3. Handles lesson ID / slug generation and source provenance preservation.
"""

from __future__ import annotations

import copy
import json
import re
import uuid
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set

from groove_eval.lesson_package import validate_schema

ROOT = Path(__file__).resolve().parent.parent
ARGON_SCHEMA_PATH = ROOT / "schemas" / "argon_breakdown.schema.json"

BOUNDARY_TOLERANCE_S = 0.040
RATE_EPS = 1e-6
# Smallest tail a cut may keep past its last segment end: about 2 frames at 24 fps, enough for the recut to keep the final beat.
MIN_TAIL_PAD_S = 0.10

CANONICAL_JOINTS: Set[str] = {
    "root",
    "spine",
    "centerShoulder",
    "leftHip",
    "leftKnee",
    "leftAnkle",
    "rightHip",
    "rightKnee",
    "rightAnkle",
    "leftShoulder",
    "leftElbow",
    "leftWrist",
    "rightShoulder",
    "rightElbow",
    "rightWrist",
    "leftHeel",
    "leftFootIndex",
    "rightHeel",
    "rightFootIndex",
    "nose",
}

JOINT_ALIASES: Dict[str, List[str]] = {
    "wrists": ["leftWrist", "rightWrist"],
    "hands": ["leftWrist", "rightWrist"],
    "ankles": ["leftAnkle", "rightAnkle"],
    "feet": ["leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"],
    "knees": ["leftKnee", "rightKnee"],
    "shoulders": ["leftShoulder", "rightShoulder"],
    "elbows": ["leftElbow", "rightElbow"],
    "face": ["nose"],
}


def load_breakdown_schema(path: Optional[Path] = None) -> Dict[str, Any]:
    """Load the argon breakdown JSON Schema."""
    with open(path or ARGON_SCHEMA_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def slugify(text: str) -> str:
    """Generate a clean slug matching ^[a-z0-9]+(-[a-z0-9]+)*$."""
    cleaned = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned if cleaned else "routine"


def validate_timemap(timemap: Sequence[Mapping[str, Any]]) -> List[str]:
    """Validate that timemap conforms to list of {out_start_s, src_start_s, dur_s}."""
    errors: List[str] = []
    if not timemap:
        errors.append("timemap must be a non-empty sequence")
        return errors

    cur_out = 0.0
    for i, piece in enumerate(timemap):
        for req in ("out_start_s", "src_start_s", "dur_s"):
            if req not in piece:
                errors.append(f"timemap[{i}]: missing required key {req!r}")
        if errors:
            continue
        out_start = float(piece["out_start_s"])
        src_start = float(piece["src_start_s"])
        dur = float(piece["dur_s"])
        if dur <= 0:
            errors.append(f"timemap[{i}].dur_s: must be > 0, got {dur}")
        if out_start < 0:
            errors.append(f"timemap[{i}].out_start_s: must be >= 0, got {out_start}")
        if src_start < 0:
            errors.append(f"timemap[{i}].src_start_s: must be >= 0, got {src_start}")
        if abs(out_start - cur_out) > 0.01:
            errors.append(f"timemap[{i}].out_start_s: expected contiguous start {cur_out:.3f}, got {out_start:.3f}")
        cur_out = out_start + dur
    return errors


def build_timemap_from_cut_plan(cut_plan: Sequence[Mapping[str, float]]) -> List[Dict[str, float]]:
    """Build a contiguous timemap from cut_plan intervals."""
    timemap: List[Dict[str, float]] = []
    cur_out = 0.0
    for cut in cut_plan:
        src_start = float(cut["src_start_s"])
        src_end = float(cut["src_end_s"])
        dur = max(0.0, src_end - src_start)
        timemap.append({
            "out_start_s": round(cur_out, 3),
            "src_start_s": round(src_start, 3),
            "dur_s": round(dur, 3),
        })
        cur_out += dur
    return timemap


def map_src_to_out(t_src: float, timemap: Sequence[Mapping[str, float]]) -> float:
    """Map a timestamp from source timeline to output recut timeline."""
    for piece in timemap:
        src_start = float(piece["src_start_s"])
        dur = float(piece["dur_s"])
        out_start = float(piece["out_start_s"])
        if src_start - RATE_EPS <= t_src <= src_start + dur + RATE_EPS:
            delta = t_src - src_start
            return round(out_start + delta, 3)
    raise ValueError(f"Source time {t_src:.3f} s falls outside of timemap {timemap}")


def pad_cut_plan(
    breakdown: Mapping[str, Any],
    tail_pad_s: float = 0.25,
    head_pad_s: float = 0.0,
) -> Dict[str, Any]:
    """Extend cut_plan pieces within source duration and usable shots.

    Pads the end of each cut_plan piece by `tail_pad_s` and the start by `head_pad_s`,
    clamped so the piece does not exceed the source duration, does not extend past
    the usable shot containing it, and does not overlap adjacent cut pieces.
    """
    res = copy.deepcopy(dict(breakdown))
    duration_s = float(res["source"]["duration_s"])
    usable_shots = [s for s in res.get("shots", []) if s.get("usable") is True]
    cut_plan = res.get("cut_plan", [])
    if not cut_plan:
        return res

    new_cuts: List[Dict[str, Any]] = []
    for i, cut in enumerate(cut_plan):
        cur_start = float(cut["src_start_s"])
        cur_end = float(cut["src_end_s"])

        # Match usable shot enclosing or overlapping this cut / its segments
        matching_shot = None
        for shot in usable_shots:
            s_start = float(shot["start_s"])
            s_end = float(shot["end_s"])
            if s_start - RATE_EPS <= cur_start and cur_end <= s_end + RATE_EPS:
                matching_shot = shot
                break

        if matching_shot is None:
            contained_segs = [
                s for s in res.get("segments", [])
                if cur_start - RATE_EPS <= float(s["start_s"]) and float(s["end_s"]) <= cur_end + RATE_EPS
            ]
            if contained_segs:
                seg_min = min(float(s["start_s"]) for s in contained_segs)
                seg_max = max(float(s["end_s"]) for s in contained_segs)
                for shot in usable_shots:
                    s_start = float(shot["start_s"])
                    s_end = float(shot["end_s"])
                    if s_start - RATE_EPS <= seg_min and seg_max <= s_end + RATE_EPS:
                        matching_shot = shot
                        break

        if matching_shot is None:
            for shot in usable_shots:
                s_start = float(shot["start_s"])
                s_end = float(shot["end_s"])
                if max(cur_start, s_start) < min(cur_end, s_end):
                    matching_shot = shot
                    break

        shot_start = float(matching_shot["start_s"]) if matching_shot else 0.0
        shot_end = float(matching_shot["end_s"]) if matching_shot else duration_s

        prev_end = float(new_cuts[-1]["src_end_s"]) if new_cuts else 0.0
        min_start = max(0.0, shot_start, prev_end)
        new_start = max(min_start, cur_start - head_pad_s)

        next_start = float(cut_plan[i + 1]["src_start_s"]) if i + 1 < len(cut_plan) else duration_s
        max_end = min(duration_s, shot_end, next_start)
        new_end = min(max_end, cur_end + tail_pad_s)

        new_start = round(new_start, 3)
        new_end = round(max(new_start, new_end), 3)

        new_cut = dict(cut)
        new_cut["src_start_s"] = new_start
        new_cut["src_end_s"] = new_end
        new_cuts.append(new_cut)

    res["cut_plan"] = new_cuts
    return res


def validate_breakdown(
    breakdown: Mapping[str, Any],
    schema: Optional[Mapping[str, Any]] = None,
    tail_pad_s: float = MIN_TAIL_PAD_S,
) -> List[str]:
    """Validate an Argon breakdown dictionary against schema and cross-field rules."""
    loaded_schema = schema if schema is not None else load_breakdown_schema()
    errors = validate_schema(breakdown, loaded_schema)
    if errors:
        return errors

    duration_s = float(breakdown["source"]["duration_s"])
    bpm = float(breakdown["bpm"])
    first_downbeat_s = float(breakdown["first_downbeat_s"])
    beat_period = 60.0 / bpm

    # 1. Target dancer exists in dancers
    dancers = breakdown["dancers"]
    target_id = breakdown["target_dancer_id"]
    dancer_ids = {d["id"] for d in dancers}
    if target_id not in dancer_ids:
        errors.append(f"$.target_dancer_id: {target_id!r} not found in dancers list {sorted(dancer_ids)}")

    # 2. Cut plan inside duration, non-overlapping, ascending
    cut_plan = breakdown["cut_plan"]
    last_end = 0.0
    for i, cut in enumerate(cut_plan):
        start = float(cut["src_start_s"])
        end = float(cut["src_end_s"])
        where = f"$.cut_plan[{i}]"
        if not (0.0 <= start < end <= duration_s + RATE_EPS):
            errors.append(f"{where}: need 0 <= src_start_s < src_end_s <= source.duration_s ({duration_s})")
        if start < last_end - RATE_EPS:
            errors.append(f"{where}: cuts must be ascending and non-overlapping (start {start} < previous end {last_end})")
        last_end = max(last_end, end)

    # 2b. Cut plan tail padding past contained segments
    segments = breakdown.get("segments", [])
    for i, cut in enumerate(cut_plan):
        start = float(cut["src_start_s"])
        end = float(cut["src_end_s"])
        where = f"$.cut_plan[{i}]"
        contained = [
            s for s in segments
            if start - RATE_EPS <= float(s["start_s"]) and float(s["end_s"]) <= end + RATE_EPS
        ]
        if contained and tail_pad_s > 0:
            last_seg_end = max(float(s["end_s"]) for s in contained)
            if end < last_seg_end + tail_pad_s - RATE_EPS:
                errors.append(
                    f"{where}.src_end_s: {end:.3f} s must extend at least {tail_pad_s:.3f} s "
                    f"past last contained segment end {last_seg_end:.3f} s (expected >= {last_seg_end + tail_pad_s:.3f} s)"
                )

    # 3. Shots inside duration, ascending
    shots = breakdown["shots"]
    last_shot_end = 0.0
    for i, shot in enumerate(shots):
        start = float(shot["start_s"])
        end = float(shot["end_s"])
        where = f"$.shots[{i}]"
        if not (0.0 <= start < end <= duration_s + RATE_EPS):
            errors.append(f"{where}: need 0 <= start_s < end_s <= source.duration_s ({duration_s})")
        if start < last_shot_end - RATE_EPS:
            errors.append(f"{where}: shots must be chronological (start {start} < previous end {last_shot_end})")
        last_shot_end = max(last_shot_end, end)

    usable_shots = [s for s in shots if s.get("usable") is True]

    # Helper: checks if an interval is completely contained within one item of intervals
    def is_contained(start: float, end: float, intervals: Sequence[Mapping[str, Any]], start_key: str, end_key: str) -> bool:
        for item in intervals:
            i_start = float(item[start_key])
            i_end = float(item[end_key])
            if i_start - RATE_EPS <= start and end <= i_end + RATE_EPS:
                return True
        return False

    # 4. Segments checks: within usable shots, inside cut_plan, ascending, on-beat
    segments = breakdown["segments"]
    seen_seg_ids = set()
    last_active_end = 0.0

    for i, seg in enumerate(segments):
        where = f"$.segments[{i}]"
        seg_id = seg["id"]
        if seg_id in seen_seg_ids:
            errors.append(f"{where}.id: duplicate segment id {seg_id!r}")
        seen_seg_ids.add(seg_id)

        start = float(seg["start_s"])
        end = float(seg["end_s"])
        if start >= end:
            errors.append(f"{where}: need start_s < end_s")

        is_full = seg.get("kind") == "full_run" or seg_id == "full"

        # Segments within usable shots
        if not is_contained(start, end, usable_shots, "start_s", "end_s"):
            errors.append(
                f"{where}: segment {seg_id!r} [{start:.3f}, {end:.3f}] is not wholly contained within a single usable shot"
            )

        # Segments within cut_plan
        if not is_contained(start, end, cut_plan, "src_start_s", "src_end_s"):
            errors.append(
                f"{where}: segment {seg_id!r} [{start:.3f}, {end:.3f}] is not wholly contained within a cut_plan interval"
            )

        # Ascending check across regular teaching segments
        if not is_full:
            if start < last_active_end - RATE_EPS:
                errors.append(
                    f"{where}: segments must be ascending (start_s {start:.3f} < previous segment end_s {last_active_end:.3f})"
                )
            last_active_end = max(last_active_end, end)

        # On-beat within +-40 ms of the bpm grid
        for key, t in (("start_s", start), ("end_s", end)):
            k = round((t - first_downbeat_s) / beat_period)
            nearest_beat = first_downbeat_s + k * beat_period
            diff = abs(t - nearest_beat)
            if diff > BOUNDARY_TOLERANCE_S + RATE_EPS:
                errors.append(
                    f"{where}.{key}: {t:.3f} s is not within {int(BOUNDARY_TOLERANCE_S * 1000)} ms of bpm grid "
                    f"(nearest beat {nearest_beat:.3f} s, diff {int(diff * 1000)} ms)"
                )

        # Beat grid point exists at segment end inside the kept range
        k_end = round((end - first_downbeat_s) / beat_period)
        beat_end = first_downbeat_s + k_end * beat_period
        matching_cut = next(
            (c for c in cut_plan if float(c["src_start_s"]) - RATE_EPS <= start <= float(c["src_end_s"]) + RATE_EPS),
            None,
        )
        if matching_cut is not None:
            c_start = float(matching_cut["src_start_s"])
            c_end = float(matching_cut["src_end_s"])
            if k_end < 0 or beat_end < c_start - RATE_EPS or beat_end > c_end + RATE_EPS:
                errors.append(
                    f"{where}.end_s: beat grid point {beat_end:.3f} s at segment end {end:.3f} s "
                    f"does not exist inside kept range [{c_start:.3f}, {c_end:.3f}]"
                )
        else:
            errors.append(
                f"{where}.end_s: beat grid point {beat_end:.3f} s at segment end {end:.3f} s "
                f"does not exist inside kept range"
            )

    # 5. Teach order check
    teach_order = breakdown["teach_order"]
    if len(teach_order) != len(set(teach_order)):
        errors.append("$.teach_order: contains duplicate segment IDs")
    for tid in teach_order:
        if tid not in seen_seg_ids:
            errors.append(f"$.teach_order: segment ID {tid!r} not found in segments")

    # 6. Occlusion windows
    windows = breakdown.get("occlusion_windows", [])
    for i, win in enumerate(windows):
        where = f"$.occlusion_windows[{i}]"
        w_start = float(win["start_s"])
        w_end = float(win["end_s"])
        if not (0.0 <= w_start < w_end <= duration_s + RATE_EPS):
            errors.append(f"{where}: need 0 <= start_s < end_s <= duration_s")

    return errors


def _resolve_joints(raw_joints: Sequence[str]) -> List[str]:
    """Map joint names / aliases to canonical joint names."""
    canonical: List[str] = []
    for j in raw_joints:
        if j in CANONICAL_JOINTS:
            canonical.append(j)
        elif j in JOINT_ALIASES:
            canonical.extend(JOINT_ALIASES[j])
    return sorted(set(canonical))


def to_lesson_source(
    breakdown: Mapping[str, Any],
    timemap: Optional[Sequence[Mapping[str, float]]] = None,
    course_slug: Optional[str] = None,
    lesson_slug: Optional[str] = None,
    lesson_id: Optional[str] = None,
    title: Optional[str] = None,
    tail_pad_s: float = 0.25,
    head_pad_s: float = 0.0,
) -> Dict[str, Any]:
    """Convert a validated Argon breakdown into Groove Coach lesson source format.

    Maps all times to the recut output timeline via timemap.
    """
    if timemap is None:
        breakdown = pad_cut_plan(breakdown, tail_pad_s=tail_pad_s, head_pad_s=head_pad_s)
        # Padding aims for tail_pad_s but stops at the usable shot's end, so only require the floor.
        errors = validate_breakdown(breakdown, tail_pad_s=min(tail_pad_s, MIN_TAIL_PAD_S))
        if errors:
            raise ValueError("Argon breakdown validation failed:\n  " + "\n  ".join(errors))
        timemap = build_timemap_from_cut_plan(breakdown["cut_plan"])
    else:
        errors = validate_breakdown(breakdown, tail_pad_s=0.0)
        if errors:
            raise ValueError("Argon breakdown validation failed:\n  " + "\n  ".join(errors))
        tm_errors = validate_timemap(timemap)
        if tm_errors:
            raise ValueError("Timemap validation failed:\n  " + "\n  ".join(tm_errors))

    source_info = breakdown["source"]
    source_url = source_info["url"]

    # Lesson ID: use provided, or deterministic UUIDv5 from source URL
    if lesson_id:
        final_lesson_id = lesson_id
    else:
        final_lesson_id = str(uuid.uuid5(uuid.NAMESPACE_URL, source_url))

    # Slugs
    final_course_slug = course_slug or slugify(breakdown.get("style", "dance-basics"))
    final_lesson_slug = lesson_slug or slugify(source_info.get("title", "routine"))
    final_title = title or source_info.get("title", "Dance Lesson")

    # Output anchor time in recut timeline
    first_downbeat_s = float(breakdown["first_downbeat_s"])
    out_anchor_s = map_src_to_out(first_downbeat_s, timemap)

    # Map teach_order: map IDs to 1..N order
    teach_order_list = breakdown.get("teach_order", [])

    # Map segments
    raw_segments = breakdown["segments"]
    has_full = any(s.get("kind") == "full_run" or s["id"] == "full" for s in raw_segments)

    converted_segments: List[Dict[str, Any]] = []
    for s in raw_segments:
        seg_id = s["id"]
        out_start = map_src_to_out(float(s["start_s"]), timemap)
        out_end = map_src_to_out(float(s["end_s"]), timemap)

        if seg_id in teach_order_list:
            order_idx = teach_order_list.index(seg_id) + 1
        elif "teach_order" in s:
            order_idx = int(s["teach_order"])
        else:
            order_idx = len(converted_segments) + 1

        seg_dict: Dict[str, Any] = {
            "id": seg_id,
            "title": s["title"],
            "start_s": out_start,
            "end_s": out_end,
            "teach_order": order_idx,
            "difficulty": int(s["difficulty"]),
            "focus": list(s["focus"]),
            "cues": list(s["cues"]),
        }
        if "kind" in s:
            seg_dict["kind"] = s["kind"]
        elif seg_id == "full":
            seg_dict["kind"] = "full_run"

        if "config_overrides" in s:
            seg_dict["config_overrides"] = dict(s["config_overrides"])
        if "adaptive_speed" in s:
            seg_dict["adaptive_speed"] = dict(s["adaptive_speed"])

        converted_segments.append(seg_dict)

    # Synthesize full_run if not provided and multiple segments exist
    if not has_full and len(converted_segments) > 1:
        min_start = min(s["start_s"] for s in converted_segments)
        max_end = max(s["end_s"] for s in converted_segments)
        all_focus = sorted({f for s in converted_segments for f in s["focus"]})
        seg_names = [s["id"] for s in sorted(converted_segments, key=lambda x: x["start_s"])]
        full_teach_order = len(converted_segments) + 1
        if "full" in teach_order_list:
            full_teach_order = teach_order_list.index("full") + 1

        converted_segments.append({
            "id": "full",
            "kind": "full_run",
            "title": "Full Routine",
            "start_s": min_start,
            "end_s": max_end,
            "teach_order": full_teach_order,
            "difficulty": max(1, min(5, round(sum(s["difficulty"] for s in converted_segments) / len(converted_segments)))),
            "focus": all_focus,
            "cues": [f"{', '.join(seg_names)} without stopping"],
        })

    # Sort teach_order numbers to ensure contiguous 1..N
    assigned_orders = [s["teach_order"] for s in converted_segments]
    expected_orders = list(range(1, len(converted_segments) + 1))
    if sorted(assigned_orders) != expected_orders:
        # Re-assign sequentially maintaining relative order
        sorted_by_order = sorted(converted_segments, key=lambda x: x["teach_order"])
        for idx, s in enumerate(sorted_by_order):
            s["teach_order"] = idx + 1

    # Map occlusion windows to lesson windows
    windows: List[Dict[str, Any]] = []
    for win in breakdown.get("occlusion_windows", []):
        w_start = map_src_to_out(float(win["start_s"]), timemap)
        w_end = map_src_to_out(float(win["end_s"]), timemap)
        kind = win.get("kind", "clasp")
        item: Dict[str, Any] = {
            "kind": kind,
            "start_s": w_start,
            "end_s": w_end,
        }
        if "mask" in win:
            item["mask"] = list(win["mask"])
        elif kind == "clasp":
            item["mask"] = ["hand_shape"]

        if "tolerance_scale" in win:
            item["tolerance_scale"] = dict(win["tolerance_scale"])
        elif "joints" in win:
            resolved = _resolve_joints(win["joints"])
            if resolved:
                item["tolerance_scale"] = {j: 2.0 for j in resolved}

        windows.append(item)

    # Assemble lesson source dictionary
    lesson_source: Dict[str, Any] = {
        "schema": "groove.lesson/1",
        "lesson_id": final_lesson_id,
        "course_slug": final_course_slug,
        "lesson_slug": final_lesson_slug,
        "package_version": 1,
        "title": final_title,
        "requires": {
            "engine_major": 2,
            "skeleton": "groove.canonical/1",
        },
        "video": {
            "mirrored": bool(breakdown.get("mirrored", False)),
            "default_display_flip": True,
        },
        "beat_grid": {
            "bpm": float(breakdown["bpm"]),
            "anchor_s": out_anchor_s,
            "source": "author_confirmed",
            "detector": "argon_beat_estimate",
        },
        "segments": converted_segments,
        "windows": windows,
        "config_overrides": dict(breakdown.get("config_overrides", {})),
        "practice": dict(breakdown.get("practice", {
            "count_in_beats": 4,
            "adaptive_speed": {
                "min_rate": 0.6,
                "start_rate": 0.7,
                "max_rate": 1.0,
                "step_up": 0.1,
                "step_down": 0.05,
                "promote_after": 2,
                "demote_after": 2,
                "unlock_next_at_rate": 0.8,
            },
        })),
        "provenance": {
            "source_url": source_url,
            "title": source_info["title"],
            "channel": source_info.get("channel", ""),
            "duration_s": float(source_info["duration_s"]),
            "pipeline": "argon",
        },
    }

    return lesson_source
