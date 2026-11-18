"""Beat grid generation and alignment for Groove Coach authoring (spec §2.1, WO-1C).

Beat detector license:
Beat This! (CPJKU, ISMIR 2024, https://github.com/CPJKU/beat_this):
- Software code: MIT License
- Pre-trained model weights: MIT License
- Annotations (CPJKU/beat_this_annotations): MIT License
- Spectrogram features (Zenodo): CC-BY-4.0
Unlike Essentia (AGPL-3.0) or madmom models (CC BY-NC-SA), Beat This! is permissible for commercial use.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from groove_eval.audio_beats import extract_beats_from_audio

BEAT_THIS_LICENSE = "MIT"
BEAT_THIS_PAPER = "Beat This! Music Beat and Downbeat Tracking (ISMIR 2024, CPJKU)"


def build_beat_grid(
    bpm: float,
    anchor_s: float,
    duration_s: float,
    *,
    source: str = "author_confirmed",
    detector: str = "beat_this_small_cpu",
    round_decimals: int = 3,
) -> Dict[str, Any]:
    """Construct a uniform 8-count beat grid anchored at `anchor_s` up to `duration_s`."""
    if bpm <= 0:
        raise ValueError(f"bpm must be positive, got {bpm}")
    if anchor_s < 0:
        raise ValueError(f"anchor_s cannot be negative, got {anchor_s}")
    if duration_s <= 0:
        raise ValueError(f"duration_s must be positive, got {duration_s}")

    beat_period = 60.0 / bpm
    beats: List[Dict[str, Any]] = []

    k = 0
    while True:
        t = anchor_s + k * beat_period
        if t > duration_s + 1e-6:
            break
        beats.append({
            "t": round(t, round_decimals),
            "phrase": (k // 8) + 1,
            "count": (k % 8) + 1,
        })
        k += 1

    return {
        "bpm": float(bpm),
        "anchor_s": float(anchor_s),
        "source": source,
        "detector": detector,
        "beats": beats,
    }


def propose_beat_grid(
    media_path: Path,
    confirmed_bpm: Optional[float] = None,
    confirmed_anchor_s: Optional[float] = None,
    duration_s: Optional[float] = None,
) -> Dict[str, Any]:
    """Run groove_eval.audio_beats as a proposal, or produce an author-confirmed grid if BPM/anchor provided."""
    media_path = Path(media_path)

    # If confirmed values are supplied, generate the confirmed grid
    if confirmed_bpm is not None and confirmed_anchor_s is not None and duration_s is not None:
        # We can still run the detector proposal in the background for logging/comparison if needed
        return build_beat_grid(
            bpm=confirmed_bpm,
            anchor_s=confirmed_anchor_s,
            duration_s=duration_s,
            source="author_confirmed",
            detector="beat_this_small_cpu",
        )

    # Run groove_eval detector proposal
    proposal = extract_beats_from_audio(media_path)
    detected_bpm = proposal["bpm"]
    beat_times = proposal["beat_times"]

    anchor = beat_times[0] if beat_times else 0.0
    dur = duration_s if duration_s is not None else (beat_times[-1] + 1.0 if beat_times else 10.0)

    if confirmed_bpm is not None or confirmed_anchor_s is not None:
        bpm = confirmed_bpm if confirmed_bpm is not None else detected_bpm
        anchor = confirmed_anchor_s if confirmed_anchor_s is not None else anchor
        return build_beat_grid(
            bpm=bpm,
            anchor_s=anchor,
            duration_s=dur,
            source="author_confirmed",
            detector=proposal.get("backend", "beat_this_small_cpu"),
        )

    # Build beat objects from detector's raw beat timestamps
    beats: List[Dict[str, Any]] = []
    for k, t in enumerate(beat_times):
        if duration_s is not None and t > duration_s + 1e-6:
            break
        beats.append({
            "t": round(t, 3),
            "phrase": (k // 8) + 1,
            "count": (k % 8) + 1,
        })

    return {
        "bpm": float(detected_bpm),
        "anchor_s": round(anchor, 3),
        "source": "detector",
        "detector": proposal.get("backend", "beat_this_small_cpu"),
        "beats": beats,
    }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description="Beat grid proposal and generation")
    parser.add_argument("media", type=Path, help="Audio or video file path")
    parser.add_argument("--bpm", type=float, default=None, help="Author-confirmed BPM")
    parser.add_argument("--anchor", type=float, default=None, help="Author-confirmed downbeat anchor (seconds)")
    parser.add_argument("--duration", type=float, default=None, help="Video duration (seconds)")
    parser.add_argument("--out", type=Path, default=None, help="Output JSON path")
    args = parser.parse_args(argv)

    print(f"Beat This! license: {BEAT_THIS_LICENSE} (open-source MIT)")
    grid = propose_beat_grid(
        args.media,
        confirmed_bpm=args.bpm,
        confirmed_anchor_s=args.anchor,
        duration_s=args.duration,
    )
    print(f"BPM: {grid['bpm']}, Anchor: {grid['anchor_s']} s, Source: {grid['source']}, Beats: {len(grid['beats'])}")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(grid, f, indent=2)
        print(f"Saved beat grid to {args.out}")
    else:
        print(json.dumps(grid, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
