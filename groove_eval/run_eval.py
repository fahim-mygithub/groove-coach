"""Headless CLI evaluation runner for Groove Coach Milestone 0 (M0) + wave-2 scoring components."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from groove_eval.generate_feature_clips import main as generate_features_main
from groove_eval.generate_golden_clips import main as generate_main
from groove_eval.scoring import load_config, score_attempt, validate_against_schema

WIDTH = 140


def _fmt_score(value: Optional[float], status: str) -> str:
    if value is None:
        return {"not_applicable": "n/a", "skipped": "skip", "disabled": "off"}.get(status, "-")
    return f"{value:.1f}"


def _evaluate(title: str, dataset: Dict[str, Any], config: Dict[str, Any]) -> List[Tuple[str, str]]:
    references = dataset["references"]
    clips = dataset["golden_clips"]

    print("=" * WIDTH)
    print(title)
    print("=" * WIDTH)
    header = (
        f"{'Clip ID':<38} | {'Move':<11} | {'Offset(ms)':>10} | {'Good+%':>6} | "
        f"{'Shape':>6} | {'Groove':>6} | {'Hits':>5} | {'Hand':>5} | {'Cov%':>4} | {'Result':<6} | "
        f"{'Expected':<13} | Top correction hint"
    )
    print(header)
    print("-" * WIDTH)

    mismatches: List[Tuple[str, str]] = []
    for clip in clips:
        ref = references[clip["move_tag"]]
        res = score_attempt(clip, ref, config)

        ok_schema, errs = validate_against_schema(res["between_rep_digest"], "between_rep_digest")
        if not ok_schema:
            mismatches.append((clip["clip_id"], f"Digest schema invalid: {errs}"))

        expected = clip["expected"]
        actual_pass = res["passed"]
        expected_pass = expected["passed"]
        status_str = "PASS" if actual_pass else "FAIL"
        exp_str = "PASS" if expected_pass else "FAIL"
        match_mark = "OK" if actual_pass == expected_pass else "MISMATCH"

        for key, component in (("hits_status", "hits"), ("hands_status", "hands")):
            if key in expected and res[component]["status"] != expected[key]:
                mismatches.append(
                    (clip["clip_id"], f"{component} status expected={expected[key]}, actual={res[component]['status']}")
                )

        print(
            f"{clip['clip_id']:<38} | {clip['move_tag']:<11} | "
            f"{res['timing']['mean_offset_ms']:>+10.1f} | "
            f"{res['timing']['good_or_better_ratio']*100:>5.0f}% | "
            f"{res['shape']['shape_score']:>6.1f} | "
            f"{res['groove']['groove_score']:>6.1f} | "
            f"{_fmt_score(res['hits']['hit_score'], res['hits']['status']):>5} | "
            f"{_fmt_score(res['hands']['hand_score'], res['hands']['status']):>5} | "
            f"{res['coverage_ratio']*100:>3.0f}% | "
            f"{status_str:<6} | {exp_str:<4} ({match_mark:<2}) | "
            f"{res['joints']['top_hint'] or '-'}"
        )
        if actual_pass != expected_pass:
            mismatches.append(
                (
                    clip["clip_id"],
                    f"expected={expected_pass}, actual={actual_pass}, issue={res['between_rep_digest']['top_deterministic_issue']}",
                )
            )

    print("-" * WIDTH)
    print(f"Summary: {len(clips) - len({m[0] for m in mismatches})}/{len(clips)} clips matched expected labels and JSON schemas.")
    return mismatches


def run_evaluation() -> int:
    root = Path(__file__).resolve().parent.parent
    fixtures_path = root / "fixtures" / "golden_clips.json"
    features_path = root / "fixtures" / "feature_clips.json"
    if not fixtures_path.exists():
        generate_main()
    if not features_path.exists():
        generate_features_main()

    config = load_config()
    mismatches: List[Tuple[str, str]] = []
    with open(fixtures_path, "r", encoding="utf-8") as f:
        mismatches += _evaluate(
            "GROOVE COACH — MILESTONE 0 HEADLESS SCORING EVALUATION REPORT (20 GOLDEN CLIPS)", json.load(f), config
        )
    print()
    with open(features_path, "r", encoding="utf-8") as f:
        mismatches += _evaluate(
            "GROOVE COACH — HIT TIMING / JOINT VERDICT / HAND STYLING FEATURE CLIPS", json.load(f), config
        )

    if mismatches:
        print("\nFailures:")
        for cid, msg in mismatches:
            print(f"  - {cid}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run_evaluation())
