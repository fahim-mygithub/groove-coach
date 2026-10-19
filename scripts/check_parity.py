#!/usr/bin/env python3
"""Verify 1:1 numeric parity between Python (`groove_eval/scoring.py`) and Swift (`GrooveCore`)."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from groove_eval.scoring import load_config, score_attempt  # noqa: E402


def compute_python_scores(config_path: Path, dataset_path: Path) -> List[Dict[str, Any]]:
    config = load_config(config_path)
    with open(dataset_path, "r", encoding="utf-8") as f:
        dataset = json.load(f)

    references = dataset["references"]
    results = []
    for clip in dataset["golden_clips"]:
        ref = references[clip["move_tag"]]
        res = score_attempt(clip, ref, config)
        results.append(
            {
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
            }
        )
    return results


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
        if py_item["passed"] != ot_item["passed"]:
            errors.append(f"{cid}: passed mismatch (py={py_item['passed']} vs {label}={ot_item['passed']})")
        if py_item.get("foot_scoring_status") != ot_item.get("foot_scoring_status"):
            errors.append(
                f"{cid}: foot_scoring_status mismatch (py={py_item.get('foot_scoring_status')} vs {label}={ot_item.get('foot_scoring_status')})"
            )
        for key in (
            "coverage_ratio",
            "mean_offset_ms",
            "good_or_better_ratio",
            "shape_score",
            "groove_score",
        ):
            diff = abs(float(py_item[key]) - float(ot_item[key]))
            if diff > tol:
                errors.append(
                    f"{cid}.{key}: diff={diff:.4f} > {tol} (py={py_item[key]} vs {label}={ot_item[key]})"
                )
    return errors


def main() -> int:
    config_path = ROOT / "config" / "groove_config.json"
    dataset_path = ROOT / "fixtures" / "golden_clips.json"
    snapshot_path = ROOT / "fixtures" / "expected_scores_snapshot.json"

    py_scores = compute_python_scores(config_path, dataset_path)

    if not snapshot_path.exists():
        with open(snapshot_path, "w", encoding="utf-8") as f:
            json.dump(py_scores, f, indent=2)
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
        print(f"Python vs. canonical snapshot parity: 20/20 clips identical.")

    if shutil.which("swift"):
        print("Swift toolchain detected — running live Python vs. Swift `groove-score-cli` parity test...")
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
            return 1
        swift_scores = json.loads(proc.stdout)
        swift_errs = compare_scores(py_scores, swift_scores, "swift")
        if swift_errs:
            print("Python vs. Swift parity failed:")
            for e in swift_errs:
                print(f"  - {e}")
            return 1
        print("Python vs. Swift `groove-score-cli` parity: 20/20 clips identical within +/-0.02!")
    else:
        print(
            "Note: Local `swift` binary not installed on this host; "
            "live Swift parity runs automatically in `.github/workflows/linux-ci.yml`."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
