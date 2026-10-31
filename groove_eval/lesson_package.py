"""Lesson package contract (spec §2.2, §8): load, validate, slice, stretch, and the adaptive-speed policy.

Mirror of ios/GrooveCore/Sources/GrooveCore/LessonPackage.swift (M1, WO-1A). Stdlib only: linux-ci has no jsonschema,
so `validate_schema` interprets the subset of JSON Schema 2020-12 that `schemas/lesson_package.schema.json` uses and
raises on any other keyword, so the schema file stays the single source of truth for structure.

Time bases:
- manifest times and `reference_pose.json` frame times are media seconds on the original video timeline;
- `slice_reference` rebases a segment so t = 0 at `segment.start_s` (pad frames before it have t < 0);
- `stretch` maps that slice to wall-clock time at playback rate r: t / r, beat_times / r, bpm * r,
  speed_pct = round(100 r). The learner take uses the same origin (the segment's first beat), so `score_attempt`
  and its millisecond thresholds are unchanged at any rate.

Usage: python -m groove_eval.lesson_package validate fixtures/lessons/example_manifest.json
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from groove_eval.scoring import load_config

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "schemas" / "lesson_package.schema.json"
MANIFEST_SCHEMA = "groove.lesson/1"

BOUNDARY_TOLERANCE_S = 0.040
RATE_EPS = 1e-9
HARD_MIN_RATE = 0.5
HARD_MAX_RATE = 1.0

# Defaults justified in spec §8 Q6.
DEFAULT_ADAPTIVE_SPEED: Dict[str, Any] = {
    "min_rate": 0.6,
    "start_rate": 0.7,
    "max_rate": 1.0,
    "step_up": 0.1,
    "step_down": 0.05,
    "promote_after": 2,
    "demote_after": 2,
    "unlock_next_at_rate": 0.8,
}

# The §3.2 config keys that do not exist in config/groove_config.json yet (WO-1B adds them).
NEW_CONFIG_KEYS: Dict[Tuple[str, ...], Dict[str, Any]] = {
    ("scoring_thresholds", "shape", "arm_weight"): {"type": "number", "minimum": 0.0, "maximum": 1.0},
    ("scoring_thresholds", "gate", "timing_source"): {"enum": ["bounce", "hits"]},
}


class LessonPackageError(ValueError):
    """A manifest, policy or rate that breaks the lesson package contract."""


# ---------------------------------------------------------------------------------------------------------------
# JSON Schema subset


_IGNORED_KEYWORDS = {"$schema", "$id", "title", "description"}
_SUPPORTED_KEYWORDS = {
    "$ref", "$defs", "const", "enum", "type", "required", "properties", "additionalProperties", "propertyNames",
    "minProperties", "items", "minItems", "maxItems", "pattern", "minLength", "minimum", "maximum",
    "exclusiveMinimum", "exclusiveMaximum",
} | _IGNORED_KEYWORDS


def _json_type_ok(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    if isinstance(value, bool):
        return False
    if expected == "number":
        return isinstance(value, (int, float))
    if expected == "integer":
        return isinstance(value, int) or (isinstance(value, float) and value.is_integer())
    raise LessonPackageError(f"unsupported schema type {expected!r}")


def _json_equal(a: Any, b: Any) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    return a == b


def _resolve_ref(ref: str, root: Mapping[str, Any]) -> Mapping[str, Any]:
    if not ref.startswith("#/"):
        raise LessonPackageError(f"only local $ref is supported, got {ref!r}")
    node: Any = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def validate_schema(doc: Any, schema: Mapping[str, Any], root: Optional[Mapping[str, Any]] = None, path: str = "$") -> List[str]:
    """Errors (`path: message`) for `doc` against the supported JSON Schema subset; empty when valid."""
    root = schema if root is None else root
    unknown = set(schema) - _SUPPORTED_KEYWORDS
    if unknown:
        raise LessonPackageError(f"{path}: unsupported schema keywords {sorted(unknown)}")
    if "$ref" in schema:
        return validate_schema(doc, _resolve_ref(schema["$ref"], root), root, path)

    errors: List[str] = []
    if "const" in schema and not _json_equal(doc, schema["const"]):
        errors.append(f"{path}: expected {schema['const']!r}")
    if "enum" in schema and not any(_json_equal(doc, v) for v in schema["enum"]):
        errors.append(f"{path}: {doc!r} not in {schema['enum']}")
    if "type" in schema and not _json_type_ok(doc, schema["type"]):
        errors.append(f"{path}: expected {schema['type']}, got {type(doc).__name__}")
        return errors

    if isinstance(doc, dict):
        for key in schema.get("required", []):
            if key not in doc:
                errors.append(f"{path}: missing required field {key!r}")
        if len(doc) < schema.get("minProperties", 0):
            errors.append(f"{path}: fewer than {schema['minProperties']} properties")
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, value in doc.items():
            sub = f"{path}.{key}"
            if "propertyNames" in schema:
                errors.extend(f"{e} (property name)" for e in validate_schema(key, schema["propertyNames"], root, sub))
            if key in props:
                errors.extend(validate_schema(value, props[key], root, sub))
            elif extra is False:
                errors.append(f"{sub}: unexpected field")
            elif isinstance(extra, dict):
                errors.extend(validate_schema(value, extra, root, sub))
    elif isinstance(doc, list):
        if len(doc) < schema.get("minItems", 0):
            errors.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(doc) > schema["maxItems"]:
            errors.append(f"{path}: more than {schema['maxItems']} items")
        if "items" in schema:
            for i, item in enumerate(doc):
                errors.extend(validate_schema(item, schema["items"], root, f"{path}[{i}]"))
    elif isinstance(doc, str):
        if len(doc) < schema.get("minLength", 0):
            errors.append(f"{path}: shorter than {schema['minLength']}")
        if "pattern" in schema and re.search(schema["pattern"], doc) is None:
            errors.append(f"{path}: {doc!r} does not match {schema['pattern']}")
    elif isinstance(doc, (int, float)) and not isinstance(doc, bool):
        if "minimum" in schema and doc < schema["minimum"]:
            errors.append(f"{path}: {doc} < minimum {schema['minimum']}")
        if "maximum" in schema and doc > schema["maximum"]:
            errors.append(f"{path}: {doc} > maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and doc <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: {doc} <= exclusiveMinimum {schema['exclusiveMinimum']}")
        if "exclusiveMaximum" in schema and doc >= schema["exclusiveMaximum"]:
            errors.append(f"{path}: {doc} >= exclusiveMaximum {schema['exclusiveMaximum']}")
    return errors


def load_schema(path: Optional[Path] = None) -> Dict[str, Any]:
    with open(path or SCHEMA_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------------------------------------------
# Manifest validation


def _check_overrides(override: Any, base: Any, path: Tuple[str, ...], errors: List[str], where: str) -> None:
    if not isinstance(override, dict):
        errors.append(f"{where}: config_overrides must be an object")
        return
    for key, value in override.items():
        sub = path + (key,)
        label = f"{where}.{'.'.join(sub)}"
        if sub in NEW_CONFIG_KEYS:
            errors.extend(validate_schema(value, NEW_CONFIG_KEYS[sub], path=label))
            continue
        if not isinstance(base, dict) or key not in base:
            errors.append(f"{label}: not a key of config/groove_config.json or a §3.2 key")
            continue
        target = base[key]
        if isinstance(target, dict):
            _check_overrides(value, target, sub, errors, where)
        elif isinstance(target, bool) or isinstance(value, bool):
            if not (isinstance(target, bool) and isinstance(value, bool)):
                errors.append(f"{label}: type differs from the bundled config")
        elif isinstance(target, (int, float)):
            if not isinstance(value, (int, float)):
                errors.append(f"{label}: expected a number")
        elif type(value) is not type(target):
            errors.append(f"{label}: type differs from the bundled config")


def _check_policy(policy: Mapping[str, Any], where: str, errors: List[str]) -> None:
    lo, hi = policy["min_rate"], policy["max_rate"]
    if not lo <= policy["start_rate"] <= hi:
        errors.append(f"{where}: need min_rate <= start_rate <= max_rate")
    if not lo <= policy["unlock_next_at_rate"] <= hi:
        errors.append(f"{where}: need min_rate <= unlock_next_at_rate <= max_rate")


def _near_beat(t: float, beats: Sequence[float]) -> bool:
    return any(abs(t - b) <= BOUNDARY_TOLERANCE_S + RATE_EPS for b in beats)


def validate_manifest(
    manifest: Mapping[str, Any],
    config: Optional[Mapping[str, Any]] = None,
    schema: Optional[Mapping[str, Any]] = None,
) -> List[str]:
    """All contract errors for a manifest: the JSON Schema first, then the cross-field rules of spec §2.2 / §8."""
    errors = validate_schema(manifest, schema if schema is not None else load_schema())
    if errors:
        return errors
    config = config if config is not None else load_config()

    duration = float(manifest["video"]["duration_s"])
    beats = [float(b["t"]) for b in manifest["beat_grid"]["beats"]]
    for i in range(1, len(beats)):
        if beats[i] <= beats[i - 1]:
            errors.append(f"$.beat_grid.beats[{i}].t: beats must be strictly increasing")
    if beats and beats[-1] > duration + RATE_EPS:
        errors.append("$.beat_grid.beats: beat after video end")

    seen_ids = set()
    for i, seg in enumerate(manifest["segments"]):
        where = f"$.segments[{i}]"
        if seg["id"] in seen_ids:
            errors.append(f"{where}.id: duplicate segment id {seg['id']!r}")
        seen_ids.add(seg["id"])
        start, end = float(seg["start_s"]), float(seg["end_s"])
        if not 0.0 <= start < end <= duration + RATE_EPS:
            errors.append(f"{where}: need 0 <= start_s < end_s <= video.duration_s")
        for key, t in (("start_s", start), ("end_s", end)):
            if not _near_beat(t, beats):
                errors.append(f"{where}.{key}: {t} is not within {int(BOUNDARY_TOLERANCE_S * 1000)} ms of a beat")
        if "config_overrides" in seg:
            _check_overrides(seg["config_overrides"], config, (), errors, f"{where}.config_overrides")
        if "adaptive_speed" in seg:
            _check_policy(seg["adaptive_speed"], f"{where}.adaptive_speed", errors)
    orders = sorted(int(s["teach_order"]) for s in manifest["segments"])
    if orders != list(range(1, len(orders) + 1)):
        errors.append(f"$.segments: teach_order must be 1..{len(orders)} with no gaps or repeats, got {orders}")

    for i, win in enumerate(manifest["windows"]):
        if not 0.0 <= float(win["start_s"]) < float(win["end_s"]) <= duration + RATE_EPS:
            errors.append(f"$.windows[{i}]: need 0 <= start_s < end_s <= video.duration_s")

    _check_overrides(manifest["config_overrides"], config, (), errors, "$.config_overrides")
    _check_policy(manifest["practice"]["adaptive_speed"], "$.practice.adaptive_speed", errors)

    files = manifest["files"]
    needed = [manifest["video"]["file"], manifest["reference"]["file"]]
    if "poster" in manifest:
        needed.append(manifest["poster"])
    for name in needed:
        if name not in files:
            errors.append(f"$.files: missing sha256 for {name!r}")
    if "manifest.json" in files:
        errors.append("$.files: manifest.json cannot list its own hash")
    return errors


def load_manifest(path: Path, validate: bool = True, config: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    if validate:
        errors = validate_manifest(manifest, config)
        if errors:
            raise LessonPackageError(f"{path}: " + "; ".join(errors))
    return manifest


# ---------------------------------------------------------------------------------------------------------------
# Lookups and config merge


def segment(manifest: Mapping[str, Any], segment_id: str) -> Dict[str, Any]:
    for seg in manifest["segments"]:
        if seg["id"] == segment_id:
            return seg
    raise LessonPackageError(f"unknown segment {segment_id!r}")


def teaching_sequence(manifest: Mapping[str, Any]) -> List[str]:
    """Segment ids in teach_order (A, B, C, D, full for IMG_4941)."""
    return [s["id"] for s in sorted(manifest["segments"], key=lambda s: int(s["teach_order"]))]


def segment_policy(manifest: Mapping[str, Any], segment_id: str) -> Dict[str, Any]:
    """The segment's own adaptive_speed policy, else the lesson's `practice.adaptive_speed`."""
    seg = segment(manifest, segment_id)
    return dict(seg.get("adaptive_speed") or manifest["practice"]["adaptive_speed"])


def deep_merge(base: Mapping[str, Any], override: Mapping[str, Any]) -> Dict[str, Any]:
    """Recursive dict merge; override wins on leaves and non-dict values replace whole subtrees."""
    out: Dict[str, Any] = {k: (deep_merge(v, {}) if isinstance(v, dict) else v) for k, v in base.items()}
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = deep_merge(value, {}) if isinstance(value, dict) else value
    return out


def segment_config(config: Mapping[str, Any], manifest: Mapping[str, Any], segment_id: str) -> Dict[str, Any]:
    """Bundled config < lesson `config_overrides` < segment `config_overrides` (spec §3.2)."""
    merged = deep_merge(config, manifest.get("config_overrides") or {})
    return deep_merge(merged, segment(manifest, segment_id).get("config_overrides") or {})


# ---------------------------------------------------------------------------------------------------------------
# Slice and stretch


def slice_reference(
    reference_clip: Mapping[str, Any],
    manifest: Mapping[str, Any],
    segment_id: str,
    pad_beats: float = 0.5,
) -> Dict[str, Any]:
    """A segment of the lesson reference as a standalone PoseClip, rebased so t = 0 at `segment.start_s`.

    Frames: media time in [start - pad, end + pad] with pad = pad_beats * 60 / bpm (context for the beat search
    window and smoothing). Beats: those in [start - 40 ms, end - 40 ms), so the beat that opens the next segment is
    not graded twice. Windows overlapping the segment are kept, rebased.
    """
    seg = segment(manifest, segment_id)
    start, end = float(seg["start_s"]), float(seg["end_s"])
    bpm = float(manifest["beat_grid"]["bpm"])
    pad = float(pad_beats) * 60.0 / bpm
    frames = []
    for f in reference_clip["frames"]:
        t = float(f["t"])
        if start - pad - RATE_EPS <= t <= end + pad + RATE_EPS:
            out = dict(f)
            out["t"] = t - start
            frames.append(out)
    beat_times = [
        float(b["t"]) - start
        for b in manifest["beat_grid"]["beats"]
        if start - BOUNDARY_TOLERANCE_S <= float(b["t"]) < end - BOUNDARY_TOLERANCE_S
    ]
    windows = [
        dict(w, start_s=float(w["start_s"]) - start, end_s=float(w["end_s"]) - start)
        for w in manifest["windows"]
        if float(w["start_s"]) < end and float(w["end_s"]) > start
    ]
    return {
        "clip_id": f"{manifest['lesson_slug']}/{segment_id}",
        "move_tag": segment_id,
        "bpm": bpm,
        "beat_times": beat_times,
        "gravity_vector": list(reference_clip.get("gravity_vector") or (0.0, -1.0, 0.0)),
        "mirrored": False,
        "audio_latency_ms": 0.0,
        "speed_pct": 100,
        "segment_start_s": start,
        "segment_end_s": end,
        "windows": windows,
        "frames": frames,
    }


def quantize_rate(rate: float) -> float:
    """Round a playback rate to 0.01 (half up), so step arithmetic never drifts (0.7 + 0.1 -> 0.8 exactly)."""
    return math.floor(float(rate) * 100.0 + 0.5) / 100.0


def check_rate(rate: float, policy: Optional[Mapping[str, Any]] = None) -> float:
    lo = float(policy["min_rate"]) if policy else HARD_MIN_RATE
    hi = float(policy["max_rate"]) if policy else HARD_MAX_RATE
    if not (lo - RATE_EPS <= float(rate) <= hi + RATE_EPS):
        raise LessonPackageError(f"rate {rate} outside [{lo}, {hi}]")
    return float(rate)


def stretch(clip: Mapping[str, Any], rate: float, policy: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """A sliced reference played at `rate`, in wall-clock time: t / rate, beat_times / rate, bpm * rate.

    Any rate in [policy.min_rate, policy.max_rate] is accepted ([0.5, 1.0] without a policy). Rate 1.0 is a copy.
    """
    r = check_rate(rate, policy)
    out = dict(clip)
    out["frames"] = [dict(f, t=float(f["t"]) / r) for f in clip["frames"]]
    out["beat_times"] = [float(b) / r for b in clip["beat_times"]]
    out["bpm"] = float(clip["bpm"]) * r
    out["speed_pct"] = int(math.floor(r * 100.0 + 0.5))
    out["rate"] = r
    if "windows" in clip:
        out["windows"] = [dict(w, start_s=float(w["start_s"]) / r, end_s=float(w["end_s"]) / r) for w in clip["windows"]]
    return out


# ---------------------------------------------------------------------------------------------------------------
# Adaptive speed


def validate_policy(policy: Mapping[str, Any]) -> None:
    schema = load_schema()
    errors = validate_schema(policy, schema["$defs"]["adaptive_speed"], schema, "adaptive_speed")
    if not errors:
        _check_policy(policy, "adaptive_speed", errors)
    if errors:
        raise LessonPackageError("; ".join(errors))


def next_rate(policy: Mapping[str, Any], history: Sequence[Mapping[str, Any]]) -> Tuple[float, bool]:
    """Playback rate for the next take of a segment, and whether the next segment is unlocked.

    `history` is this segment's takes, oldest first: `{"passed": bool, "rate": float}` (`rate` optional; it defaults
    to the rate the policy offered). Replaying from `start_rate`:
    - a take at a different rate than the current one (the learner overrode it) moves the current rate there and
      restarts both streaks;
    - `promote_after` consecutive passes step up by `step_up`, `demote_after` consecutive fails step down by
      `step_down`; either step restarts the streaks; rates are clamped to [min_rate, max_rate] and quantized to 0.01;
    - unlocked once any take passed at a rate >= `unlock_next_at_rate` (sticky).
    """
    validate_policy(policy)
    lo, hi = float(policy["min_rate"]), float(policy["max_rate"])
    up, down = float(policy["step_up"]), float(policy["step_down"])
    promote, demote = int(policy["promote_after"]), int(policy["demote_after"])
    unlock_at = float(policy["unlock_next_at_rate"])

    def clamp(r: float) -> float:
        return min(hi, max(lo, quantize_rate(r)))

    current = clamp(float(policy["start_rate"]))
    passes = fails = 0
    unlocked = False
    for take in history:
        if take.get("rate") is not None:
            taken_at = clamp(float(take["rate"]))
            if abs(taken_at - current) > RATE_EPS:
                current, passes, fails = taken_at, 0, 0
        if take["passed"]:
            passes, fails = passes + 1, 0
            if current >= unlock_at - RATE_EPS:
                unlocked = True
        else:
            passes, fails = 0, fails + 1
        if passes >= promote:
            current, passes = clamp(current + up), 0
        elif fails >= demote:
            current, fails = clamp(current - down), 0
    return current, unlocked


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2 or argv[0] != "validate":
        print("usage: python -m groove_eval.lesson_package validate <manifest.json>", file=sys.stderr)
        return 2
    with open(argv[1], "r", encoding="utf-8") as f:
        errors = validate_manifest(json.load(f))
    for e in errors:
        print(e)
    print(f"{argv[1]}: {'OK' if not errors else f'{len(errors)} error(s)'}")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
