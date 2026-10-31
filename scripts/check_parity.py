#!/usr/bin/env python3
"""Verify 1:1 numeric parity between Python (`groove_eval/scoring.py`) and Swift (`GrooveCore`).

Three datasets are scored: the 20 golden clips (`fixtures/golden_clips.json`), the feature clips
(`fixtures/feature_clips.json`, arm hits + hand landmarks) so smoothing, hit timing, joint verdicts and hand
styling are all covered, and the lesson clips (`fixtures/lesson_clips.json`: arm shape term, hits timing gate,
clasp windows, rate stretch, retargeting, velocity / occlusion tolerances). A clip's `config_overrides` are
deep-merged over the config before scoring, here and in groove-score-cli. Python results are checked against
`fixtures/expected_scores_snapshot.json`, and against the Swift `groove-score-cli` whenever a Swift toolchain is
installed (always in linux-ci).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from groove_eval.scoring import load_config, merge_config, score_attempt  # noqa: E402

DATASETS = ("golden_clips.json", "feature_clips.json", "lesson_clips.json")

NUMERIC_KEYS = (
    "coverage_ratio",
    "mean_offset_ms",
    "good_or_better_ratio",
    "shape_score",
    "groove_score",
    "hit_score",
    "hit_mean_offset_ms",
    "hand_score",
    "arm_error_deg",
)
EXACT_KEYS = (
    "passed",
    "foot_scoring_status",
    "smoothing_applied",
    "hit_status",
    "hit_matched_count",
    "hand_status",
    "hand_samples",
    "hand_user_shape",
    "hand_reference_shape",
    "joint_status",
    "joint_top_hint",
    "joint_counts",
    "joint_severities",
)


def _severities(verdicts: List[Dict[str, Any]], angle_verdicts: List[Dict[str, Any]]) -> Dict[str, str]:
    out = {v["joint"]: v["severity"] for v in verdicts}
    out.update({"angle:" + v["joint"]: v["severity"] for v in angle_verdicts})
    return out


def flatten_python(res: Dict[str, Any]) -> Dict[str, Any]:
    hits, hands, joints = res["hits"], res["hands"], res["joints"]
    out = {
        "clip_id": res["clip_id"],
        "passed": res["passed"],
        "coverage_ratio": res["coverage_ratio"],
        "foot_scoring_status": res["foot_scoring_status"],
        "mean_offset_ms": res["timing"]["mean_offset_ms"],
        "good_or_better_ratio": res["timing"]["good_or_better_ratio"],
        "shape_score": res["shape"]["shape_score"],
        "groove_score": res["groove"]["groove_score"],
        "worst_beat": res["timing"]["worst_beat"],
        "worst_joints": res["shape"]["worst_joints"],
        "smoothing_applied": res["smoothing_applied"],
        "hit_status": hits["status"],
        "hit_score": hits["hit_score"],
        "hit_matched_count": hits["matched_count"],
        "hit_mean_offset_ms": hits["mean_offset_ms"],
        "hand_status": hands["status"],
        "hand_score": hands["hand_score"],
        "hand_samples": hands["samples"],
        "hand_user_shape": hands["user_shape"],
        "hand_reference_shape": hands["reference_shape"],
        "joint_status": joints["status"],
        "joint_top_hint": joints["top_hint"],
        "joint_counts": joints["counts"],
        "joint_severities": _severities(joints["verdicts"], joints["angle_verdicts"]),
    }
    # Keys added with the lesson features appear only when set, so older snapshot entries stay byte-identical.
    if res["shape"].get("arm_error_deg") is not None:
        out["arm_error_deg"] = res["shape"]["arm_error_deg"]
    return out


def flatten_swift(item: Dict[str, Any]) -> Dict[str, Any]:
    """Map a Swift `AttemptScoreResult` (JSON from groove-score-cli; nil optionals are omitted) to the flat record."""
    hits = item.get("hit_timing", {})
    hands = item.get("hand_styling", {})
    joints = item.get("joint_feedback", {})
    return {
        "clip_id": item["clip_id"],
        "passed": item["passed"],
        "coverage_ratio": item["coverage_ratio"],
        "foot_scoring_status": item.get("foot_scoring_status"),
        "mean_offset_ms": item["mean_offset_ms"],
        "good_or_better_ratio": item["good_or_better_ratio"],
        "shape_score": item["shape_score"],
        "groove_score": item["groove_score"],
        "smoothing_applied": item.get("smoothing_applied"),
        "hit_status": hits.get("status"),
        "hit_score": hits.get("hit_score"),
        "hit_matched_count": hits.get("matched_count"),
        "hit_mean_offset_ms": hits.get("mean_offset_ms"),
        "hand_status": hands.get("status"),
        "hand_score": hands.get("hand_score"),
        "hand_samples": hands.get("samples"),
        "hand_user_shape": hands.get("user_shape"),
        "hand_reference_shape": hands.get("reference_shape"),
        "joint_status": joints.get("status"),
        "joint_top_hint": joints.get("top_hint"),
        "joint_counts": joints.get("counts"),
        "joint_severities": _severities(joints.get("verdicts", []), joints.get("angle_verdicts", [])),
        "arm_error_deg": item.get("arm_error_deg"),
    }


def compute_python_scores(config_path: Path, dataset_path: Path) -> List[Dict[str, Any]]:
    config = load_config(config_path)
    with open(dataset_path, "r", encoding="utf-8") as f:
        dataset = json.load(f)

    references = dataset["references"]
    return [
        flatten_python(
            score_attempt(clip, references[clip["move_tag"]], merge_config(config, clip.get("config_overrides")))
        )
        for clip in dataset["golden_clips"]
    ]


def compare_scores(
    py_scores: List[Dict[str, Any]],
    other_scores: List[Dict[str, Any]],
    label: str,
    tol: float = 0.02,
) -> List[str]:
    errors: List[str] = []
    other_by_id = {item["clip_id"]: item for item in other_scores}

    for py_item in py_scores:
        cid = py_item["clip_id"]
        if cid not in other_by_id:
            errors.append(f"{cid}: missing from {label} output")
            continue
        ot_item = other_by_id[cid]
        for key in EXACT_KEYS:
            if py_item.get(key) != ot_item.get(key):
                errors.append(f"{cid}.{key}: mismatch (py={py_item.get(key)} vs {label}={ot_item.get(key)})")
        for key in NUMERIC_KEYS:
            a: Optional[float] = py_item.get(key)
            b: Optional[float] = ot_item.get(key)
            if a is None or b is None:
                if a is not b:
                    errors.append(f"{cid}.{key}: presence mismatch (py={a} vs {label}={b})")
                continue
            diff = abs(float(a) - float(b))
            if diff > tol:
                errors.append(f"{cid}.{key}: diff={diff:.4f} > {tol} (py={a} vs {label}={b})")
    return errors


def run_swift(config_path: Path, dataset_path: Path) -> Optional[List[Dict[str, Any]]]:
    proc = subprocess.run(
        [
            "swift",
            "run",
            "--package-path",
            str(ROOT / "ios" / "GrooveCore"),
            "groove-score-cli",
            str(config_path),
            str(dataset_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        print("Swift CLI failed:\n", proc.stderr)
        return None
    return [flatten_swift(item) for item in json.loads(proc.stdout)]


def main() -> int:
    config_path = ROOT / "config" / "groove_config.json"
    snapshot_path = ROOT / "fixtures" / "expected_scores_snapshot.json"

    py_by_dataset = {name: compute_python_scores(config_path, ROOT / "fixtures" / name) for name in DATASETS}
    py_scores = [item for name in DATASETS for item in py_by_dataset[name]]

    if not snapshot_path.exists():
        with open(snapshot_path, "w", encoding="utf-8") as f:
            json.dump(py_scores, f, indent=2)
            f.write("\n")
        print(f"Wrote canonical score snapshot to {snapshot_path}")
    else:
        with open(snapshot_path, "r", encoding="utf-8") as f:
            snap_scores = json.load(f)
        snap_errs = compare_scores(py_scores, snap_scores, "snapshot")
        if snap_errs:
            print("Snapshot drift detected:")
            for e in snap_errs:
                print(f"  - {e}")
            return 1
        print(f"Python vs. canonical snapshot parity: {len(py_scores)}/{len(py_scores)} clips identical.")

    if shutil.which("swift"):
        print("Swift toolchain detected — running live Python vs. Swift `groove-score-cli` parity test...")
        for name in DATASETS:
            swift_scores = run_swift(config_path, ROOT / "fixtures" / name)
            if swift_scores is None:
                return 1
            swift_errs = compare_scores(py_by_dataset[name], swift_scores, "swift")
            if swift_errs:
                print(f"Python vs. Swift parity failed on {name}:")
                for e in swift_errs:
                    print(f"  - {e}")
                return 1
            n = len(py_by_dataset[name])
            print(f"Python vs. Swift `groove-score-cli` parity on {name}: {n}/{n} clips identical within +/-0.02!")
    else:
        print(
            "Note: Local `swift` binary not installed on this host; "
            "live Swift parity runs automatically in `.github/workflows/linux-ci.yml`."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
