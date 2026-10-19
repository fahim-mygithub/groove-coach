"""Headless CLI evaluation runner for Groove Coach Milestone 0 (M0)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from groove_eval.generate_golden_clips import main as generate_main
from groove_eval.scoring import load_config, score_attempt, validate_against_schema


def run_evaluation() -> int:
    root = Path(__file__).resolve().parent.parent
    fixtures_path = root / "fixtures" / "golden_clips.json"
    if not fixtures_path.exists():
        generate_main()

    with open(fixtures_path, "r", encoding="utf-8") as f:
        dataset = json.load(f)

    config = load_config()
    references = dataset["references"]
    clips = dataset["golden_clips"]

    print("=" * 112)
    print("GROOVE COACH — MILESTONE 0 HEADLESS SCORING EVALUATION REPORT (20 GOLDEN CLIPS)")
    print("=" * 112)
    header = (
        f"{'Clip ID':<38} | {'Move':<11} | {'Offset(ms)':>10} | {'Good+%':>6} | "
        f"{'Shape':>6} | {'Groove':>6} | {'Cov%':>5} | {'Result':<6} | {'Expected':<8}"
    )
    print(header)
    print("-" * 112)

    mismatches = []
    for clip in clips:
        ref = references[clip["move_tag"]]
        res = score_attempt(clip, ref, config)

        ok_schema, errs = validate_against_schema(res["between_rep_digest"], "between_rep_digest")
        if not ok_schema:
            mismatches.append((clip["clip_id"], f"Digest schema invalid: {errs}"))

        actual_pass = res["passed"]
        expected_pass = clip["expected"]["passed"]
        status_str = "PASS" if actual_pass else "FAIL"
        exp_str = "PASS" if expected_pass else "FAIL"
        match_mark = "OK" if actual_pass == expected_pass else "MISMATCH"

        print(
            f"{clip['clip_id']:<38} | {clip['move_tag']:<11} | "
            f"{res['timing']['mean_offset_ms']:>+10.1f} | "
            f"{res['timing']['good_or_better_ratio']*100:>5.0f}% | "
            f"{res['shape']['shape_score']:>6.1f} | "
            f"{res['groove']['groove_score']:>6.1f} | "
            f"{res['coverage_ratio']*100:>4.0f}% | "
            f"{status_str:<6} | {exp_str:<4} ({match_mark})"
        )
        if actual_pass != expected_pass:
            mismatches.append(
                (
                    clip["clip_id"],
                    f"expected={expected_pass}, actual={actual_pass}, issue={res['between_rep_digest']['top_deterministic_issue']}",
                )
            )

    print("-" * 112)
    passed_checks = len(clips) - len(mismatches)
    print(f"Summary: {passed_checks}/{len(clips)} golden clips matched expected labels and JSON schemas.")
    if mismatches:
        print("\nFailures:")
        for cid, msg in mismatches:
            print(f"  - {cid}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run_evaluation())
